import Foundation
import Network
import Darwin

/// Persists timing metadata locally and observes coarse connection changes for the live router.
@MainActor
public final class AdaptiveRouter {
    /// Namespaces default metadata by host app, including unsandboxed macOS and command-line consumers.
    public nonisolated static var defaultCacheDirectory: URL {
        let application = Bundle.main.bundleIdentifier ?? Bundle.main.executableURL?.standardizedFileURL.path
            ?? ProcessInfo.processInfo.processName
        return RoutingFingerprint.cacheDirectory(application: application,
            root: URL.applicationSupportDirectory.appendingPathComponent("AdaptiveModelRouting", isDirectory: true))
    }

    /// Tags an in-flight request so an old network response cannot calibrate a new connection.
    public struct Snapshot: Sendable {
        public let connection: PerformanceProfile.Connection
        public let generation: Int
        public let profileGeneration: Int
    }

    /// Invalidates calibration after an OS update that may replace either model's implementation.
    private struct Cache: Codable {
        let version: Int
        let system: String
        let profile: PerformanceProfile
        let identity: String?
    }

    public private(set) var profile = PerformanceProfile()
    private var connection = PerformanceProfile.Connection(kind: .unknown)
    private var generation = 0
    private var profileGeneration = 0
    private var identity: String?
    public private(set) var persistence: RoutingPersistence = .disk
    public private(set) var storageStatus: RoutingStorageStatus = .notPersisted
    private var lastPathUpdate: ContinuousClock.Instant?
    private let directory: URL
    private let system: String
    public let configuration: RoutingConfiguration
    private let monitor: NWPathMonitor?
    private var maySave = true
    private var file: URL { directory.appendingPathComponent("latency.json") }

    /// Loads a device-local, backup-excluded profile; tests can disable live path monitoring.
    /// A supplied identifier restricts cache reuse; otherwise the stored identity is retained until explicitly updated.
    public init(
        directory: URL = AdaptiveRouter.defaultCacheDirectory,
        system: String = ProcessInfo.processInfo.operatingSystemVersionString,
        monitorConnection: Bool = true,
        configuration: RoutingConfiguration = .init(),
        persistence: RoutingPersistence = .disk, calibrationIdentifier: String? = nil
    ) {
        self.directory = directory
        self.system = system
        self.configuration = configuration
        self.persistence = persistence
        self.identity = calibrationIdentifier.map { RoutingFingerprint.make([$0]) }
        self.monitor = monitorConnection ? NWPathMonitor() : nil
        if persistence == .memoryOnly { storageStatus = .memoryOnly }
        else {
            do {
                let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: file))
                if cache.version != 1 { maySave = false; storageStatus = .preservedCache }
                else if cache.system == system && (calibrationIdentifier == nil || cache.identity == identity) {
                    profile = cache.profile
                    identity = cache.identity
                    storageStatus = .persisted
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // A new cache starts uncalibrated.
            } catch { maySave = false; storageStatus = .preservedCache }
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
    public func snapshot() -> Snapshot { Snapshot(connection: connection, generation: generation, profileGeneration: profileGeneration) }

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
        deadline: RoutingDeadline? = nil,
        shouldFallback: @escaping @MainActor (InferenceRoute, any Error) -> Bool = { _, error in InferenceExecutor.isRetryable(error) },
        cloud: @escaping @MainActor () async throws -> Value?, onDevice: @escaping @MainActor () async throws -> Value
    ) async throws -> Value? {
        try await respondDetailed(inputTokens: inputTokens, localContextCapacity: localContextCapacity,
            policy: policy, workload: workload, deadline: deadline, shouldFallback: shouldFallback, cloud: cloud, onDevice: onDevice).value
    }

    /// Reports original preference, actual provider and attempts without retaining model content.
    /// Native errors still throw; onAttempt exposes failure/cancellation metadata before propagation.
    public func respondDetailed<Value>(
        inputTokens: Int, localContextCapacity: Int,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init(),
        availability: RoutingAvailability = .init(), deadline: RoutingDeadline? = nil,
        shouldFallback: @escaping @MainActor (InferenceRoute, any Error) -> Bool = { _, error in InferenceExecutor.isRetryable(error) },
        onAttempt: ((RoutingAttempt) -> Void)? = nil,
        cloud: @escaping @MainActor () async throws -> Value?, onDevice: @escaping @MainActor () async throws -> Value
    ) async throws -> RoutingResult<Value> {
        try await withRequest(deadline: deadline, onAttempt: onAttempt) { context in
            try await self.performDetailed(context: context, inputTokens: inputTokens,
                localContextCapacity: localContextCapacity, policy: policy, workload: workload,
                availability: availability, shouldFallback: shouldFallback, cloud: cloud, onDevice: onDevice)
        }
    }

    /// Shares one deadline and attempt scope with adapter preflight rather than starting a second timeout.
    func withRequest<Value>(deadline: RoutingDeadline?, onAttempt: ((RoutingAttempt) -> Void)?,
        operation: @escaping @MainActor (RoutingRequestContext) async throws -> Value) async throws -> Value {
        let context = try RoutingRequestContext(deadline: deadline ?? configuration.requestDeadline, observer: onAttempt)
        return try await RoutingRequestRunner.run(context: context) { try await operation(context) }
    }

    /// Executes within the caller's request scope so streaming and preflight share cancellation and diagnostics.
    func performDetailed<Value>(context: RoutingRequestContext, inputTokens: Int, localContextCapacity: Int,
        policy: RoutingPolicy, workload: RoutingWorkload, availability: RoutingAvailability,
        calibrationIdentifier: String? = nil, onDecision: ((RoutingDecision) -> Void)? = nil, canFallback: () -> Bool = { true },
        shouldFallback: (InferenceRoute, any Error) -> Bool,
        cloud: @MainActor () async throws -> Value?, onDevice: @MainActor () async throws -> Value
    ) async throws -> RoutingResult<Value> {
        try context.checkActive()
        if let calibrationIdentifier { updateCalibrationIdentifier(calibrationIdentifier) }
        let snapshot = snapshot()
        let decision = decision(inputTokens: inputTokens, localCapacity: localContextCapacity,
            policy: policy, workload: workload, availability: availability)
        onDecision?(decision)
        let fits = InferenceExecutor.fitsLocal(inputTokens: inputTokens, localCapacity: localContextCapacity,
            responseReserve: max(configuration.localResponseReserve, workload.expectedOutputTokens ?? 0))
        let value = try await InferenceExecutor.execute(preferred: decision.route,
            canUseLocalWhole: fits && availability.onDevice, policy: policy, canFallback: canFallback,
            shouldFallback: { model, error in
                let retry = shouldFallback(model, error)
                if retry && !Task.isCancelled && snapshot.profileGeneration == self.profileGeneration
                    && (model == .onDevice || snapshot.generation == self.generation) {
                    self.profile.recordFailure(model: model, connection: snapshot.connection, now: .now,
                        configuration: self.configuration)
                    self.save()
                }
                return retry
            }, cloud: {
                guard availability.cloud else { return nil }
                return try await track(model: .cloud, inputTokens: inputTokens, snapshot: snapshot,
                    workload: workload, context: context, available: { $0 != nil }, operation: cloud)
            }, onDevice: {
                try await track(model: .onDevice, inputTokens: inputTokens, snapshot: snapshot,
                    workload: workload, context: context, available: { _ in true }, operation: onDevice)
            })
        let status: RoutingResultStatus = value != nil ? .completed
            : (policy != .cloudRequired && availability.onDevice && !fits ? .requiresChunking : .unavailable)
        return RoutingResult(value: value, status: status, decision: decision,
            route: context.attempts.last(where: { $0.outcome == .succeeded })?.route, attempts: context.attempts, availability: availability)
    }

    /// Measures one operation and rejects late results before they can train the profile.
    private func track<Value>(model: InferenceRoute, inputTokens: Int, snapshot: Snapshot, workload: RoutingWorkload,
        context: RoutingRequestContext, available: (Value) -> Bool, operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        try context.begin(model)
        do {
            let value = try await measure(model: model, inputTokens: inputTokens, snapshot: snapshot,
                workload: workload, recordErrors: false, available: available) {
                    let value = try await operation()
                    try context.checkActive()
                    return value
                }
            context.finishAttempt(available(value) ? .succeeded : .unavailable)
            return value
        } catch {
            let outcome: RoutingAttempt.Outcome = (error as? RoutingRequestError) == .deadlineExceeded ? .timedOut
                : (error is CancellationError || Task.isCancelled ? .cancelled : .failed)
            context.finishAttempt(outcome)
            throw error
        }
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
            guard !Task.isCancelled, let self, snapshot.generation == self.generation, snapshot.profileGeneration == self.profileGeneration else { return }
            self.profile.recordFailure(connection: snapshot.connection, now: .now, configuration: self.configuration)
            self.save()
        } : nil
        defer { slowWatch?.cancel() }
        do {
            let result = try await withTaskCancellationHandler {
                try await operation()
            } onCancel: {
                slowWatch?.cancel()
            }
            try Task.checkCancellation()
            let elapsed = started.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            if snapshot.profileGeneration == profileGeneration && (model == .onDevice || snapshot.generation == generation) {
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
            if recordErrors && InferenceExecutor.isRetryable(error) && snapshot.profileGeneration == profileGeneration
                && (model == .onDevice || snapshot.generation == generation) {
                profile.recordFailure(model: model, connection: snapshot.connection, now: .now, configuration: configuration)
                save()
            }
            throw error
        }
    }

    /// Clears learned timings and, in disk mode, removes the owned calibration file.
    public func resetProfile() throws {
        if persistence == .disk { try removeCache() }
        profileGeneration += 1
        profile = .init()
        maySave = true
        storageStatus = persistence == .memoryOnly ? .memoryOnly : .notPersisted
    }

    /// Changes storage policy; disabling disk storage clears the owned cache by default.
    public func setPersistence(_ value: RoutingPersistence, clearExistingCache: Bool = true) throws {
        if value == .memoryOnly, clearExistingCache { try removeCache(); maySave = true }
        if value == .disk {
            do {
                let existing = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: file))
                maySave = existing.version == 1
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { maySave = true }
            catch { maySave = false }
        }
        persistence = value
        profileGeneration += 1
        storageStatus = value == .memoryOnly ? .memoryOnly : .notPersisted
        if value == .disk { save() }
    }

    /// Invalidates model/workload calibration without ever persisting the identifier verbatim.
    public func updateCalibrationIdentifier(_ value: String?) {
        let next = value.map { RoutingFingerprint.make([$0]) }
        guard next != identity else { return }
        identity = next
        profileGeneration += 1
        profile = .init()
        save()
    }

    /// Deletes only this router's metadata file and preserves unrelated files in the cache directory.
    private func removeCache() throws {
        let result = file.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            let status = Darwin.unlink(path)
            return (status, errno)
        }
        if result.0 != 0 && result.1 != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: result.1) ?? .EIO) }
    }

    /// Writes bounded metadata only; storage failure must never interrupt recording or inference.
    private func save() {
        guard persistence == .disk else { storageStatus = .memoryOnly; return }
        guard maySave else { storageStatus = .preservedCache; return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let data = try JSONEncoder().encode(Cache(version: 1, system: system, profile: profile, identity: identity))
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            storageStatus = .persisted
        } catch { storageStatus = .unavailable }

    }
}
