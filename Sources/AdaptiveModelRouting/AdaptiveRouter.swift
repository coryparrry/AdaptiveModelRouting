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
    public func choose(
        inputTokens: Int, localCapacity: Int, now: Date = .now,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init()
    ) -> InferenceRoute {
        profile.choose(inputTokens: inputTokens, localCapacity: localCapacity, connection: connection,
            now: now, configuration: configuration, policy: policy, workload: workload)
    }

    /// Explains the current preference without running either provider or changing calibration.
    public func decision(
        inputTokens: Int, localCapacity: Int, now: Date = .now,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init(),
        availability: RoutingAvailability = .init()
    ) -> RoutingDecision {
        profile.decision(inputTokens: inputTokens, localCapacity: localCapacity, connection: connection,
            now: now, configuration: configuration, policy: policy, workload: workload, availability: availability)
    }

    /// Preserves the original value-only API and native error/cancellation behavior.
    public func respond<Value>(
        inputTokens: Int, localContextCapacity: Int,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init(),
        shouldFallback: (InferenceRoute, any Error) -> Bool = { _, error in InferenceExecutor.isRetryable(error) },
        cloud: () async throws -> Value?, onDevice: () async throws -> Value
    ) async throws -> Value? {
        try await respondDetailed(inputTokens: inputTokens, localContextCapacity: localContextCapacity,
            policy: policy, workload: workload, shouldFallback: shouldFallback, cloud: cloud, onDevice: onDevice).value
    }

    /// Reports original preference, actual provider and attempts without retaining model content.
    /// Native errors still throw; onAttempt exposes failure/cancellation metadata before propagation.
    public func respondDetailed<Value>(
        inputTokens: Int, localContextCapacity: Int,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init(),
        availability: RoutingAvailability = .init(),
        shouldFallback: (InferenceRoute, any Error) -> Bool = { _, error in InferenceExecutor.isRetryable(error) },
        onAttempt: ((RoutingAttempt) -> Void)? = nil,
        cloud: () async throws -> Value?, onDevice: () async throws -> Value
    ) async throws -> RoutingResult<Value> {
        let snapshot = snapshot()
        let decision = decision(inputTokens: inputTokens, localCapacity: localContextCapacity,
            policy: policy, workload: workload, availability: availability)
        let fits = InferenceExecutor.fitsLocal(inputTokens: inputTokens, localCapacity: localContextCapacity,
            responseReserve: max(configuration.localResponseReserve, workload.expectedOutputTokens ?? 0))
        var attempts: [RoutingAttempt] = []
        let finish: (RoutingAttempt) -> Void = { attempt in
            attempts.append(attempt)
            onAttempt?(attempt)
        }
        let value = try await InferenceExecutor.respond(preferred: decision.route,
            canUseLocalWhole: fits && availability.onDevice, policy: policy,
            shouldFallback: { model, error in
                let retry = shouldFallback(model, error)
                if retry && !Task.isCancelled && (model == .onDevice || snapshot.generation == self.generation) {
                    self.profile.recordFailure(model: model, connection: snapshot.connection, now: .now,
                        configuration: self.configuration)
                    self.save()
                }
                return retry
            }, cloud: {
                guard availability.cloud else { return nil }
                return try await track(model: .cloud, inputTokens: inputTokens, snapshot: snapshot,
                    workload: workload, available: { $0 != nil }, finish: finish, operation: cloud)
            }, onDevice: {
                try await track(model: .onDevice, inputTokens: inputTokens, snapshot: snapshot,
                    workload: workload, available: { _ in true }, finish: finish, operation: onDevice)
            })
        let status: RoutingResultStatus = value != nil ? .completed
            : (policy == .automatic && availability.onDevice && !fits ? .requiresChunking : .unavailable)
        return RoutingResult(value: value, status: status, decision: decision,
            route: attempts.last(where: { $0.outcome == .succeeded })?.route, attempts: attempts, availability: availability)
    }

    /// Emits exactly one content-free event per attempted provider, including failed and cancelled operations.
    private func track<Value>(
        model: InferenceRoute, inputTokens: Int, snapshot: Snapshot, workload: RoutingWorkload,
        available: (Value) -> Bool, finish: (RoutingAttempt) -> Void,
        operation: () async throws -> Value
    ) async throws -> Value {
        let started = ContinuousClock.now
        do {
            let value = try await measure(model: model, inputTokens: inputTokens, snapshot: snapshot,
                workload: workload, recordErrors: false, available: available, operation: operation)
            finish(.init(route: model, seconds: elapsed(since: started),
                outcome: available(value) ? .succeeded : .unavailable))
            return value
        } catch {
            finish(.init(route: model, seconds: elapsed(since: started),
                outcome: error is CancellationError || Task.isCancelled ? .cancelled : .failed))
            throw error
        }
    }

    /// Converts monotonic elapsed time into seconds for diagnostics.
    private func elapsed(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
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
    /// Standalone measurement records thrown failures only for recognized temporary network errors.
    public func measure<Value>(
        model: InferenceRoute, inputTokens: Int, snapshot: Snapshot,
        workload: RoutingWorkload = .init(),
        available: (Value) -> Bool = { _ in true },
        operation: () async throws -> Value
    ) async throws -> Value {
        try await measure(model: model, inputTokens: inputTokens, snapshot: snapshot,
            workload: workload, recordErrors: true, available: available, operation: operation)
    }

    /// Integrated execution classifies errors once in the executor; standalone measurement uses network defaults.
    private func measure<Value>(
        model: InferenceRoute, inputTokens: Int, snapshot: Snapshot,
        workload: RoutingWorkload, recordErrors: Bool,
        available: (Value) -> Bool = { _ in true },
        operation: () async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        let started = clock.now
        let slowWatch: Task<Void, Never>? = model == .cloud ? Task { [weak self, slowCloudAfter = configuration.slowCloudAfter] in
            do { try await Task.sleep(for: slowCloudAfter) }
            catch { return }
            guard !Task.isCancelled, let self, snapshot.generation == self.generation else { return }
            self.profile.recordFailure(connection: snapshot.connection, now: .now, configuration: self.configuration)
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
                        connection: snapshot.connection, now: .now, workload: workload, configuration: configuration)
                } else if model == .cloud {
                    profile.recordFailure(connection: snapshot.connection, now: .now, configuration: configuration)
                }
                save()
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            if recordErrors && InferenceExecutor.isRetryable(error)
                && (model == .onDevice || snapshot.generation == generation) {
                profile.recordFailure(model: model, connection: snapshot.connection, now: .now, configuration: configuration)
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
