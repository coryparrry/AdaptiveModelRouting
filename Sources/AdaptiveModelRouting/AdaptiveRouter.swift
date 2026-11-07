import Foundation
import Network

/// Persists timing metadata locally and observes coarse connection changes for the live router.
@MainActor
public final class AdaptiveRouter {

    /// Tags an in-flight request so an old network response cannot calibrate a new connection.
    public struct Snapshot: Sendable {
        public let connection: PerformanceProfile.Connection
        public let generation: Int
    }

    /// Invalidates calibration after an OS update that may replace either model's implementation.
    private struct Cache: Codable {
        let version: Int
        let system: String
        let profile: PerformanceProfile
    }

    public private(set) var profile = PerformanceProfile()
    private var connection = PerformanceProfile.Connection(kind: .unknown)
    private var generation = 0
    private var lastPathUpdate: ContinuousClock.Instant?
    private let directory: URL
    private let system: String
    public let configuration: RoutingConfiguration
    private let monitor: NWPathMonitor?
    private var maySave = true
    private var file: URL { directory.appendingPathComponent("latency.json") }

    /// Loads a device-local, backup-excluded profile; tests can disable live path monitoring.
    public init(
        directory: URL = URL.applicationSupportDirectory.appendingPathComponent("AdaptiveModelRouting"),
        system: String = ProcessInfo.processInfo.operatingSystemVersionString,
        monitorConnection: Bool = true,
        configuration: RoutingConfiguration = .init()
    ) {
        self.directory = directory
        self.system = system
        self.configuration = configuration
        self.monitor = monitorConnection ? NWPathMonitor() : nil
        do {
            let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: file))
            if cache.version != 1 { maySave = false }
            else if cache.system == system { profile = cache.profile }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // An unused cache starts with the PCC-first policy.
        } catch {
            maySave = false
        }
        monitor?.pathUpdateHandler = { [weak self] path in
            let kind: PerformanceProfile.Connection.Kind
            if path.status == .unsatisfied { kind = .offline }
            else if path.usesInterfaceType(.wifi) { kind = .wifi }
            else if path.usesInterfaceType(.cellular) { kind = .cellular }
            else if path.usesInterfaceType(.wiredEthernet) { kind = .wired }
            else { kind = .other }
            let connection = PerformanceProfile.Connection(
                kind: kind, expensive: path.isExpensive, constrained: path.isConstrained)
            let observedAt = ContinuousClock.now
            Task { @MainActor [weak self] in self?.updateConnection(connection, observedAt: observedAt) }
        }
        monitor?.start(queue: DispatchQueue(label: "AdaptiveModelRouting.connection"))
    }

    /// Stops observation when an isolated test router or the app releases this instance.
    isolated deinit { monitor?.cancel() }

    /// Captures coarse path identity and request generation without retaining network names.
    public func snapshot() -> Snapshot { Snapshot(connection: connection, generation: generation) }

    /// Chooses a lane using current device history and current network health.
    public func choose(inputTokens: Int, localCapacity: Int, now: Date = .now) -> InferenceRoute {
        profile.choose(inputTokens: inputTokens, localCapacity: localCapacity, connection: connection, now: now, configuration: configuration)
    }

    /// Selects, measures and falls back between caller-supplied model operations without retaining their content.
    public func respond<Value>(
        inputTokens: Int, localContextCapacity: Int,
        cloud: () async throws -> Value?,
        onDevice: () async throws -> Value
    ) async throws -> Value? {
        let snapshot = snapshot()
        let preferred = choose(inputTokens: inputTokens, localCapacity: localContextCapacity)
        let fits = InferenceExecutor.fitsLocal(inputTokens: inputTokens, localCapacity: localContextCapacity,
            responseReserve: configuration.localResponseReserve)
        return try await InferenceExecutor.respond(preferred: preferred, canUseLocalWhole: fits, cloud: {
            try await measure(model: .cloud, inputTokens: inputTokens, snapshot: snapshot,
                available: { $0 != nil }, operation: cloud)
        }, onDevice: {
            try await measure(model: .onDevice, inputTokens: inputTokens, snapshot: snapshot, operation: onDevice)
        })
    }

    /// Invalidates cloud history after a path update while preserving device-only speed observations.
    public func updateConnection(
        _ value: PerformanceProfile.Connection, observedAt: ContinuousClock.Instant = .now
    ) {
        if let lastPathUpdate, observedAt < lastPathUpdate { return }
        lastPathUpdate = observedAt
        if connection.kind != .unknown { profile.changedConnection(value) }
        connection = value
        generation += 1
        save()
    }

    /// Measures only the request already selected; calibration never duplicates a meeting request.
    public func measure<Value>(
        model: InferenceRoute, inputTokens: Int, snapshot: Snapshot,
        available: (Value) -> Bool = { _ in true },
        operation: () async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        let started = clock.now
        let slowWatch: Task<Void, Never>? = model == .cloud ? Task { [weak self, slowCloudAfter = configuration.slowCloudAfter] in
            do { try await Task.sleep(for: slowCloudAfter) }
            catch { return }
            guard !Task.isCancelled, let self, snapshot.generation == self.generation else { return }
            self.profile.recordFailure(connection: snapshot.connection, now: .now)
            self.save()
        } : nil
        defer { slowWatch?.cancel() }
        do {
            let result = try await operation()
            try Task.checkCancellation()
            let elapsed = started.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            if model == .onDevice || snapshot.generation == generation {
                if available(result) {
                    profile.record(model: model, tokens: inputTokens, seconds: seconds,
                        connection: snapshot.connection, now: .now)
                } else if model == .cloud {
                    profile.recordFailure(connection: snapshot.connection, now: .now)
                }
                save()
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            if model == .onDevice || snapshot.generation == generation {
                profile.recordFailure(model: model, connection: snapshot.connection, now: .now)
                save()
            }
            throw error
        }
    }

    /// Writes bounded metadata only; storage failure must never interrupt recording or inference.
    private func save() {
        guard maySave else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let data = try JSONEncoder().encode(Cache(version: 1, system: system, profile: profile))
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
        } catch { /* Performance calibration is optional; the inference result remains usable. */ }
    }
}
