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
        let lastCloudUse: Date?
        let cloudRetryAfter: Date?
        let lastLocalLearning: Date?
    }

    public private(set) var profile = PerformanceProfile()
    private var cloudRetryAfter: Date?
    private var connection = PerformanceProfile.Connection(kind: .unknown)
    private var generation = 0
    private var profileGeneration = 0
    private var identity: String?
    public private(set) var persistence: RoutingPersistence = .disk
    public private(set) var storageStatus: RoutingStorageStatus = .notPersisted
    private var lastPathUpdate: ContinuousClock.Instant?
    private var lastNativePath: NWPath?
    private var lastLocalLearning: Date?
    /// Supports opt-in, content-free diagnostics in integration qualification without built-in telemetry.
    var onConnectionObservation: ((RoutingConnectionObservation) -> Void)?
    private let directory: URL
    private let system: String
    public let configuration: RoutingConfiguration
    private let monitor: NWPathMonitor?
    private var maySave = true
    private let calibration: RoutingCalibrationCoordinator
    private var file: URL { directory.appendingPathComponent("latency.json") }

    /// Loads a device-local, backup-excluded profile; tests can disable live path monitoring.
    /// A supplied identifier restricts cache reuse; otherwise the stored identity is retained until explicitly updated.
    public init(
        directory: URL = AdaptiveRouter.defaultCacheDirectory,
        system: String = ProcessInfo.processInfo.operatingSystemVersionString,
        monitorConnection: Bool = true,
        configuration: RoutingConfiguration = .fastest,
        persistence: RoutingPersistence = .disk, calibrationIdentifier: String? = nil
    ) {
        self.directory = directory
        self.system = system
        self.configuration = configuration
        self.persistence = persistence
        self.identity = calibrationIdentifier.map { RoutingFingerprint.make([$0]) }
        self.monitor = monitorConnection ? NWPathMonitor() : nil
        self.calibration = RoutingCalibrationCoordinator(awaitStartupObservations: monitorConnection)
        if persistence == .memoryOnly { storageStatus = .memoryOnly }
        else {
            do {
                let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: file))
                if cache.version == 1 {
                    mergeCloudPacing(from: cache)
                    lastLocalLearning = cache.lastLocalLearning
                }
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
            let observedAt = ContinuousClock.now
            Task { @MainActor [weak self] in self?.receiveNativePath(path, observedAt: observedAt) }
        }
        monitor?.start(queue: DispatchQueue(label: "AdaptiveModelRouting.connection"))
    }

    /// Stops observation when an isolated test router or the app releases this instance.
    isolated deinit { monitor?.cancel() }

    /// Reports background calibration separately from foreground request attempts.
    public var isCalibrating: Bool { calibration.isRunning }

    /// Exposes content-free startup readiness to internal integration qualification without changing routing previews.
    var isStartupCloudCalibrationDeferred: Bool { calibration.startupCloudCalibrationDeferred }
    /// Contains timing and outcome only; shadow output is never exposed as a second answer.
    public var lastCalibrationAttempt: RoutingAttempt? { calibration.lastAttempt }
    /// Waits for the currently running calibration, without starting another inference.
    public func waitForCalibration() async { await calibration.wait() }
    /// Stops background inference when the app no longer wants to spend calibration resources.
    public func cancelCalibration() { calibration.cancel() }

    /// Captures coarse path identity and request generation without retaining network names.
    public func snapshot() -> Snapshot { Snapshot(connection: connection, generation: generation, profileGeneration: profileGeneration) }

    /// Chooses a lane using current device history and current network health.
    public func choose(
        inputTokens: Int, localCapacity: Int, now: Date = .now,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init()
    ) -> InferenceRoute {
        decision(inputTokens: inputTokens, localCapacity: localCapacity, now: now, policy: policy, workload: workload).route
    }

    /// Explains the current preference without running either provider or changing calibration.
    public func decision(
        inputTokens: Int, localCapacity: Int, now: Date = .now,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init(),
        availability: RoutingAvailability = .init()
    ) -> RoutingDecision {
        let ready = providerAvailability(availability, now: now)
        let decision = profile.executionDecision(inputTokens: inputTokens, localCapacity: localCapacity, connection: connection,
            now: now, configuration: configuration, policy: policy, workload: workload, availability: ready,
            lastCloudUse: calibration.lastCloudUse, lastLocalLearning: lastLocalLearning ?? .distantPast)
        if !permitsCloud(now: now), decision.reason == .cloudUnavailable {
            return .init(route: .onDevice, reason: .cloudBackoff)
        }
        return decision
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
                availability: availability, shouldFallback: shouldFallback,
                cloud: { _, _ in try await cloud() }, onDevice: { _, _ in try await onDevice() })
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
        shouldFallback: @escaping @MainActor (InferenceRoute, any Error) -> Bool,
        cloudPermission: @escaping @MainActor (Bool) -> Bool = { _ in true },
        onProbeFallback: ((Value, InferenceRoute) throws -> Void)? = nil,
        cloud: @escaping @MainActor (RoutingRequestContext, Bool) async throws -> Value?,
        onDevice: @escaping @MainActor (RoutingRequestContext, Bool) async throws -> Value
    ) async throws -> RoutingResult<Value> {
        try context.checkActive()
        let availability = providerAvailability(availability, now: .now)
            .restricted(to: policy, conserveQuota: configuration.conserveCloudQuota)
        let suppliedCloudPermission = cloudPermission
        let cloudPermission: @MainActor (Bool) -> Bool = { calibration in
            self.permitsCloud(now: .now) && suppliedCloudPermission(calibration)
        }
        if !availability.permitsCloudCalibration { calibration.cancelCloudProbe() }
        if let calibrationIdentifier { updateCalibrationIdentifier(calibrationIdentifier) }
        let snapshot = snapshot()
        let decisionDate = Date.now
        let decision = decision(inputTokens: inputTokens, localCapacity: localContextCapacity, now: decisionDate,
            policy: policy, workload: workload, availability: availability)
        if case .paired = configuration.calibration, decision.route == .cloud,
           decision.reason == .insufficientEvidence, decision.localEstimate != nil, decision.cloudEstimate == nil {
            // Consume the successful observation synchronously, including before reentrant observers.
            // Strictly exceed every nonfuture sample even when the wall clock has equal readings.
            let consumedAfter = max(decisionDate, calibration.lastCloudUse ?? decisionDate)
            calibration.recordCloudUse(at: Date(timeIntervalSinceReferenceDate: consumedAfter.timeIntervalSinceReferenceDate.nextUp))
            save()
        }
        if case .paired = configuration.calibration, decision.route == .onDevice, decision.reason == .localCalibration {
            // Local learning cannot reuse a failed or abandoned attempt, including after a relaunch.
            let consumedAfter = max(decisionDate, lastLocalLearning ?? decisionDate)
            lastLocalLearning = Date(timeIntervalSinceReferenceDate: consumedAfter.timeIntervalSinceReferenceDate.nextUp)
            save()
        }
        onDecision?(decision)
        let fits = InferenceExecutor.fitsLocal(inputTokens: inputTokens, localCapacity: localContextCapacity,
            responseReserve: max(configuration.localResponseReserve, workload.expectedOutputTokens ?? 0))
        var classified: [InferenceRoute: Bool] = [:]
        let classify: @MainActor (InferenceRoute, any Error, RoutingRequestContext) -> Bool = { model, error, scope in
            guard (try? scope.checkActive()) != nil else { return false }
            if let previous = classified[model] { return previous }
            let retry = shouldFallback(model, error)
            classified[model] = retry
            if retry && (try? scope.checkActive()) != nil && snapshot.profileGeneration == self.profileGeneration
                && (model == .onDevice || snapshot.generation == self.generation) {
                self.profile.recordFailure(model: model, connection: snapshot.connection, now: .now,
                    configuration: self.configuration)
                self.save()
            }
            return retry
        }
        let required = profile.needsCalibration(inputTokens: inputTokens, localCapacity: localContextCapacity,
            connection: snapshot.connection, now: .now, configuration: configuration, policy: policy,
            workload: workload, availability: availability, decision: decision)
        var probe: RoutingProbe<Value>?
        var comparisonID: UUID?
        let probeRoute: InferenceRoute = decision.route == .cloud ? .onDevice : .cloud
        if calibration.shouldProbe(required: required, configuration: configuration.calibration,
            route: probeRoute, cloudInterval: configuration.cloudRetryInterval),
           case .paired(_, let timeout) = configuration.calibration {
            let route: InferenceRoute = decision.route == .cloud ? .onDevice : .cloud
            let remaining = context.cutoff.map { ContinuousClock.now.duration(to: $0) } ?? timeout
            guard remaining > .zero else { throw RoutingRequestError.deadlineExceeded }
            let pairID = UUID()
            comparisonID = pairID
            probe = try RoutingProbe(route: route, deadline: .after(min(timeout, remaining)),
                onAttempt: { [calibration] in calibration.record($0) }) { probeContext in
                    do {
                        if route == .cloud && !cloudPermission(true) { return nil }
                        return try await self.track(model: route, inputTokens: inputTokens, snapshot: snapshot,
                            workload: workload, context: probeContext, comparisonID: pairID, available: { $0 != nil }) {
                                if route == .cloud {
                                    self.calibration.recordCloudUse()
                                    self.save()
                                    try probeContext.checkActive()
                                    return try await cloud(probeContext, true)
                                }
                                return try await onDevice(probeContext, true)
                            }
                    } catch {
                        if !(error is CancellationError), !Task.isCancelled,
                           (error as? RoutingRequestError) != .deadlineExceeded { _ = classify(route, error, probeContext) }
                        throw error
                    }
                }
            if let probe {
                calibration.register(probe)
                context.onAbort = { probe.cancel() }
            }
        }
        let value: Value? = try await InferenceExecutor.execute(preferred: decision.route,
            canUseLocalWhole: fits && availability.onDevice, policy: policy, canFallback: canFallback,
            shouldFallback: { classify($0, $1, context) }, cloud: {
                guard availability.cloud else { return nil }
                if let probe, probe.route == .cloud {
                    return try await consumeProbe(probe, context: context, onValue: onProbeFallback)
                }
                guard cloudPermission(false) else { return nil }
                return try await track(model: .cloud, inputTokens: inputTokens, snapshot: snapshot,
                    workload: workload, context: context, comparisonID: comparisonID, available: { $0 != nil }) {
                        self.calibration.recordCloudUse()
                        self.save()
                        try context.checkActive()
                        return try await cloud(context, false)
                    }
            }, onDevice: {
                if let probe, probe.route == .onDevice {
                    guard let value = try await consumeProbe(probe, context: context, onValue: onProbeFallback)
                        else { throw RoutingRequestError.emptyStream }
                    return value
                }
                return try await track(model: .onDevice, inputTokens: inputTokens, snapshot: snapshot,
                    workload: workload, context: context, comparisonID: comparisonID, available: { _ in true }) { try await onDevice(context, false) }
            })
        let status: RoutingResultStatus = value != nil ? .completed
            : (policy != .cloudRequired && availability.onDevice && !fits ? .requiresChunking : .unavailable)
        return RoutingResult(value: value, status: status, decision: decision,
            route: context.attempts.last(where: { $0.outcome == .succeeded })?.route, attempts: context.attempts, availability: availability)
    }

    /// Reuses an already running secondary call during fallback without training its timing twice.
    private func consumeProbe<Value>(_ probe: RoutingProbe<Value>, context: RoutingRequestContext,
        onValue: ((Value, InferenceRoute) throws -> Void)?
    ) async throws -> Value? {
        try context.begin(probe.route)
        probe.promoteToForeground()
        do {
            let value = try await probe.task.value.value
            try context.checkActive()
            if let value { try onValue?(value, probe.route) }
            context.finishAttempt(value == nil ? .unavailable : .succeeded)
            return value
        } catch {
            let error = context.effectiveError(error)
            context.finishAttempt((error as? RoutingRequestError) == .deadlineExceeded ? .timedOut
                : (error is CancellationError || Task.isCancelled ? .cancelled : .failed))
            throw error
        }
    }

    /// Measures one operation and rejects late results before they can train the profile.
    private func track<Value>(model: InferenceRoute, inputTokens: Int, snapshot: Snapshot, workload: RoutingWorkload,
        context: RoutingRequestContext, comparisonID: UUID?, available: (Value) -> Bool, operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        try context.begin(model)
        do {
            let value = try await measure(model: model, inputTokens: inputTokens, snapshot: snapshot,
                workload: workload, recordErrors: false, comparisonID: comparisonID, context: context, available: available) {
                    let value = try await operation()
                    try context.checkActive()
                    return value
                }
            context.finishAttempt(available(value) ? .succeeded : .unavailable)
            return value
        } catch {
            let error = context.effectiveError(error)
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
        receiveConnection(value, nativePath: nil, observedAt: observedAt)
    }

    /// Observes every unequal native state while preserving historical priors for opaque reassessment.
    func receiveNativePath(_ path: NWPath, observedAt: ContinuousClock.Instant = .now) {
        receiveConnection(RoutingConnectionObservation.connection(for: path), nativePath: path, observedAt: observedAt)
    }

    /// Applies ordered transitions atomically before emitting an optional identity-free diagnostic value.
    private func receiveConnection(_ value: PerformanceProfile.Connection, nativePath: NWPath?,
        observedAt: ContinuousClock.Instant) {
        let previousPath = lastNativePath
        let nativeEqual = nativePath.flatMap { path in previousPath.map { $0 == path } }
        let changes = RoutingConnectionObservation.changes(from: previousPath, to: nativePath)
        if lastPathUpdate.map({ observedAt >= $0 }) ?? true { lastNativePath = nativePath }
        applyConnectionObservation(value, native: nativePath != nil, nativeEqual: nativeEqual,
            changes: changes, observedAt: observedAt)
    }

    /// Commits ordered evidence independently of native object construction for deterministic replay.
    func applyConnectionObservation(_ value: PerformanceProfile.Connection, native: Bool,
        nativeEqual: Bool?, changes: [String: Bool], observedAt: ContinuousClock.Instant) {
        let disposition = RoutingConnectionObservation.disposition(last: lastPathUpdate,
            observedAt: observedAt, nativeEqual: nativeEqual)
        let previousConnection = connection
        let discardHistory = RoutingConnectionObservation.shouldDiscardCloudHistory(previous: previousConnection,
            current: value, native: native, changes: changes)
        let generationBefore = generation
        if disposition != .stale { lastPathUpdate = observedAt }
        if disposition == .applied {
            calibration.cancel()
            if discardHistory { profile.changedConnection(value) }
            connection = value
            generation += 1
            save()
        }
        if disposition != .stale && (native || value.kind != .unknown) {
            calibration.recordConnectionObservation()
        }
        let event = RoutingConnectionObservation(source: native ? "native" : "manual",
            disposition: disposition, observedAt: observedAt, previousConnection: previousConnection,
            connection: value, generationBefore: generationBefore, generationAfter: generation,
            nativeEqual: nativeEqual, nativeChanges: changes)
        event.log(discardedHistory: disposition == .applied && discardHistory,
            cloudSamples: profile.samples.filter { $0.model == .cloud }.count)
        onConnectionObservation?(event)
    }

    /// Measures one provider operation, including secondary operations scheduled by paired calibration.
    /// Standalone measurement records thrown failures only for recognized temporary network errors.
    public func measure<Value>(
        model: InferenceRoute, inputTokens: Int, snapshot: Snapshot,
        workload: RoutingWorkload = .init(),
        available: (Value) -> Bool = { _ in true },
        operation: () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        if model == .cloud { calibration.recordCloudUse(); save() }
        return try await measure(model: model, inputTokens: inputTokens, snapshot: snapshot,
            workload: workload, recordErrors: true, available: available, operation: operation)
    }

    /// Integrated execution classifies errors once in the executor; standalone measurement uses network defaults.
    private func measure<Value>(
        model: InferenceRoute, inputTokens: Int, snapshot: Snapshot,
        workload: RoutingWorkload, recordErrors: Bool, comparisonID: UUID? = nil, context: RoutingRequestContext? = nil,
        available: (Value) -> Bool = { _ in true },
        operation: () async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        let started = clock.now
        let slowWatch: Task<Void, Never>? = model == .cloud ? Task { [weak self, slowCloudAfter = configuration.slowCloudAfter] in
            do { try await Task.sleep(for: slowCloudAfter) }
            catch { return }
            guard !Task.isCancelled, let self, snapshot.generation == self.generation, snapshot.profileGeneration == self.profileGeneration else { return }
            if let context, (try? context.checkActive()) == nil { return }
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
                let accepted = available(result)
                try Task.checkCancellation()
                // A public predicate may synchronously reset identity, change the path or cancel this task.
                if snapshot.profileGeneration == profileGeneration && (model == .onDevice || snapshot.generation == generation) {
                    if accepted {
                        profile.record(model: model, tokens: inputTokens, seconds: seconds,
                            connection: snapshot.connection, now: .now, workload: workload, configuration: configuration,
                            comparisonID: comparisonID)
                        if model == .onDevice && inputTokens > 0 && seconds > 0 {
                            calibration.recordLocalObservation()
                        }
                    } else if model == .cloud {
                        profile.recordFailure(connection: snapshot.connection, now: .now, configuration: configuration)
                    }
                    save()
                }
            }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if model == .cloud { recordRetryDeadline(error) }
            try Task.checkCancellation()
            if recordErrors && InferenceExecutor.isRetryable(error) && snapshot.profileGeneration == profileGeneration
                && (model == .onDevice || snapshot.generation == generation) {
                profile.recordFailure(model: model, connection: snapshot.connection, now: .now, configuration: configuration)
                save()
            }
            throw error
        }
    }

    /// Tests provider-wide retry eligibility independently of calibration identity or connection history.
    private func permitsCloud(now: Date) -> Bool { cloudRetryAfter.map { now >= $0 } ?? true }

    /// Masks cloud readiness while a known server reset deadline remains in the future.
    private func providerAvailability(_ value: RoutingAvailability, now: Date) -> RoutingAvailability {
        .init(onDevice: value.onDevice, cloud: value.cloud && permitsCloud(now: now), cloudQuota: value.cloudQuota)
    }

    /// Keeps the longest finite provider retry hint without storing an error message or response content.
    func recordRetryDeadline(_ error: any Error) {
        guard let date = (error as? any RoutingRetryAfterProviding)?.routingRetryAfter,
              date.timeIntervalSinceReferenceDate.isFinite, date > .now else { return }
        let next = max(cloudRetryAfter ?? date, date)
        guard next != cloudRetryAfter else { return }
        cloudRetryAfter = next
        save()
    }

    /// Retains the most restrictive known pacing when adopting an existing disk cache.
    private func mergeCloudPacing(from cache: Cache) {
        if let deadline = cache.cloudRetryAfter {
            cloudRetryAfter = max(cloudRetryAfter ?? deadline, deadline)
        }
        if let lastUse = cache.lastCloudUse ?? cache.profile.samples.filter({ $0.model == .cloud }).map(\.date).max() {
            calibration.recordCloudUse(at: lastUse)
        }
    }

    /// Clears learned timings while preserving any active provider retry deadline and its pacing metadata.
    public func resetProfile() throws {
        let retainDeadline = !permitsCloud(now: .now)
        if persistence == .disk {
            if retainDeadline { try writeCache(profile: .init()) }
            else { try removeCache() }
        }
        calibration.cancel()
        profileGeneration += 1
        profile = .init()
        maySave = true
        storageStatus = persistence == .memoryOnly ? .memoryOnly : (retainDeadline ? .persisted : .notPersisted)
    }

    /// Changes storage policy; disabling disk storage clears the owned cache by default.
    public func setPersistence(_ value: RoutingPersistence, clearExistingCache: Bool = true) throws {
        if value == .memoryOnly, clearExistingCache { try removeCache(); maySave = true }
        if value == .disk {
            do {
                let existing = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: file))
                maySave = existing.version == 1
                if maySave { mergeCloudPacing(from: existing) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { maySave = true }
            catch { maySave = false }
        }
        persistence = value
        calibration.cancel()
        profileGeneration += 1
        storageStatus = value == .memoryOnly ? .memoryOnly : .notPersisted
        if value == .disk { save() }
    }

    /// Invalidates model/workload calibration without ever persisting the identifier verbatim.
    public func updateCalibrationIdentifier(_ value: String?) {
        let next = value.map { RoutingFingerprint.make([$0]) }
        guard next != identity else { return }
        calibration.cancel()
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
            try writeCache(profile: profile)
            storageStatus = .persisted
        } catch { storageStatus = .unavailable }
    }

    /// Atomically replaces the owned metadata, preserving the previous file on write failure.
    private func writeCache(profile: PerformanceProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let data = try JSONEncoder().encode(Cache(version: 1, system: system, profile: profile, identity: identity,
            lastCloudUse: calibration.lastCloudUse, cloudRetryAfter: cloudRetryAfter, lastLocalLearning: lastLocalLearning))
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
}
