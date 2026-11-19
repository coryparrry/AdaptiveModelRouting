import Foundation

/// Tracks actual provider-worker exit independently of the deadline/result gate.
@MainActor
private final class RoutingWorkCompletion {
    private(set) var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Releases ownership waiters exactly once, including cancellation before worker start.
    func finish() {
        guard !finished else { return }
        finished = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    /// Waits for execution to stop, rather than merely for its result to be abandoned.
    func wait() async {
        if finished { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Keeps arbitrary provider output on MainActor while its task exposes a Sendable reference.
@MainActor
final class RoutingProbeValue<Value> {
    let value: Value?
    /// Retains a temporary result only until calibration or foreground fallback consumes it.
    init(_ value: Value?) { self.value = value }
}

/// Owns a bounded secondary inference that can also satisfy foreground fallback without a duplicate call.
@MainActor
final class RoutingProbe<Value> {
    let route: InferenceRoute
    let context: RoutingRequestContext
    let task: Task<RoutingProbeValue<Value>, any Error>
    private let completion: RoutingWorkCompletion
    var workerFinished: Bool { completion.finished }
    private(set) var isForeground = false

    /// Starts an independent deadline scope; foreground completion does not stop a healthy probe.
    init(route: InferenceRoute, deadline: RoutingDeadline, onAttempt: @escaping (RoutingAttempt) -> Void,
        operation: @escaping @MainActor (RoutingRequestContext) async throws -> Value?
    ) throws {
        self.route = route
        let context = try RoutingRequestContext(deadline: deadline, observer: onAttempt)
        self.context = context
        let completion = RoutingWorkCompletion()
        self.completion = completion
        context.onWorkerFinished = { completion.finish() }
        task = Task { @MainActor in
            let value = try await RoutingRequestRunner.run(context: context) { try await operation(context) }
            return RoutingProbeValue(value)
        }
    }

    /// Stops the timer, invalidates late output and requests cooperative provider cancellation.
    func cancel() {
        context.terminate(CancellationError())
        task.cancel()
    }

    /// Awaits only this bounded probe, including cleanup after timeout or cancellation.
    func wait() async { _ = await task.result }

    /// Retains the secondary execution slot until even a cancellation-ignoring provider exits.
    func waitForWorker() async { await completion.wait() }

    /// Protects already-admitted recovery from unrelated requests cancelling optional calibration.
    func promoteToForeground() { isForeground = true }
}

/// Counts eligible requests while pacing optional cloud use independently of timing success or profile resets.
struct RoutingCalibrationSchedule {
    private var requestsSinceProbe = 0
    private(set) var lastCloudUse: Date?

    /// Uses both cadence and a minimum cloud-use interval; missing evidence cannot bypass the quota cooldown.
    mutating func shouldProbe(required: Bool?, configuration: RoutingCalibration, route: InferenceRoute,
        cloudInterval: TimeInterval, now: Date
    ) -> Bool {
        guard let required, case .paired(let frequency, _) = configuration else { return false }
        if requestsSinceProbe < frequency { requestsSinceProbe += 1 }
        guard required || requestsSinceProbe >= frequency else { return false }
        return route != .cloud || permitsOptionalCloud(at: now, interval: cloudInterval)
    }

    /// Rechecks the cooldown independently of request cadence at optional dispatch.
    func permitsOptionalCloud(at now: Date, interval: TimeInterval) -> Bool {
        guard let lastCloudUse else { return true }
        return now.timeIntervalSince(lastCloudUse) >= interval
    }

    /// Reserves quota pacing at actual cloud callback dispatch, including failed or cancelled operations.
    mutating func recordCloudUse(at date: Date) { lastCloudUse = max(lastCloudUse ?? date, date) }

    /// Restarts request counting while retaining the cloud-use cooldown.
    mutating func resetCadence() { requestsSinceProbe = 0 }
}

/// Limits secondary inference to one job per router and schedules continued request-driven sampling.
@MainActor
final class RoutingCalibrationCoordinator {
    private var identifier: UUID?
    private var cancelJob: (() -> Void)?
    private var waitForJob: (() async -> Void)?
    private var workerFinished: (() -> Bool)?
    private var schedule = RoutingCalibrationSchedule()
    private var route: InferenceRoute?
    private(set) var lastAttempt: RoutingAttempt?
    private(set) var awaitsStartupLocalObservation: Bool
    private var awaitsInitialConnectionObservation: Bool
    var startupCloudCalibrationDeferred: Bool { awaitsStartupLocalObservation || awaitsInitialConnectionObservation }
    var isRunning: Bool { identifier != nil }
    var lastCloudUse: Date? { schedule.lastCloudUse }

    /// Requires live local work and initial connection state before optional paid work for a newly monitored owner.
    init(awaitStartupObservations: Bool = false) {
        awaitsStartupLocalObservation = awaitStartupObservations
        awaitsInitialConnectionObservation = awaitStartupObservations
    }

    /// Accepts initial native or explicit known connection state without treating it as model work.
    func recordConnectionObservation() { awaitsInitialConnectionObservation = false }

    /// Opens startup calibration after successful admitted local work without consuming cloud quota or cadence.
    func recordLocalObservation() { awaitsStartupLocalObservation = false }

    /// Counts only requests eligible to use both providers; required cold/stale evidence probes immediately.
    func shouldProbe(required: Bool?, configuration: RoutingCalibration, route: InferenceRoute,
        cloudInterval: TimeInterval, now: Date = .now
    ) -> Bool {
        guard !isRunning, !(route == .cloud && startupCloudCalibrationDeferred) else { return false }
        return schedule.shouldProbe(required: required, configuration: configuration, route: route,
            cloudInterval: cloudInterval, now: now)
    }

    /// Detects cloud use between scheduling a probe and its worker starting.
    func permitsOptionalCloud(interval: TimeInterval) -> Bool { schedule.permitsOptionalCloud(at: .now, interval: interval) }

    /// Records admitted cloud work even when it later times out or supplies no calibration timing.
    func recordCloudUse(at date: Date = .now) { schedule.recordCloudUse(at: date) }

    /// Stops optional cloud work when a newer request observes quota pressure or cloud ineligibility.
    func cancelCloudProbe() { if route == .cloud { cancel() } }

    /// Tracks the probe until it finishes without retaining its prompt or output after completion.
    func register<Value>(_ probe: RoutingProbe<Value>) {
        let token = UUID()
        identifier = token
        route = probe.route
        schedule.resetCadence()
        cancelJob = { if !probe.isForeground { probe.cancel() } }
        waitForJob = { await probe.wait() }
        workerFinished = { probe.workerFinished }
        Task { [weak self] in
            await probe.wait()
            await probe.waitForWorker()
            self?.release(token)
        }
    }

    /// Exposes timing/outcome metadata separately from the user-facing attempt list.
    func record(_ attempt: RoutingAttempt) { lastAttempt = attempt }

    /// Awaits the currently owned probe without starting a benchmark or waiting for future requests.
    func wait() async {
        let token = identifier
        await waitForJob?()
        if let token, workerFinished?() == true { release(token) }
    }

    /// Cancels owned work and resets cadence when the app, profile or connection changes.
    func cancel() {
        cancelJob?()
        if let token = identifier, workerFinished?() == true { release(token) }
        schedule.resetCadence()
    }

    /// Frees the slot only for its current owner, after actual worker completion.
    private func release(_ token: UUID) {
        guard identifier == token else { return }
        identifier = nil
        cancelJob = nil
        waitForJob = nil
        workerFinished = nil
        route = nil
    }
}
