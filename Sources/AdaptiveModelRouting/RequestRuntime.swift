import Foundation
import Synchronization

/// Limits the entire request, including adapter preflight and all permitted recovery attempts.
public nonisolated enum RoutingDeadline: Equatable, Sendable {
    case after(Duration)
    case unlimited
}

/// Request-control failures are distinct from provider failures and never authorize deadline fallback.
public nonisolated enum RoutingRequestError: LocalizedError, Equatable, Sendable {
    case deadlineExceeded
    case invalidDeadline
    case emptyStream

    public var errorDescription: String? {
        switch self {
        case .deadlineExceeded: "The request exceeded its deadline."
        case .invalidDeadline: "A request deadline must be positive."
        case .emptyStream: "The model finished without producing any output."
        }
    }
}

/// Tracks one request and emits terminal attempt metadata even when a provider ignores cancellation.
@MainActor
final class RoutingRequestContext {
    let cutoff: ContinuousClock.Instant?
    private var active = true
    private var termination: (any Error)?
    private var attempt: (route: InferenceRoute, started: ContinuousClock.Instant)?
    private let observer: ((RoutingAttempt) -> Void)?
    private(set) var attempts: [RoutingAttempt] = []
    var onAbort: (() -> Void)?
    var onWorkerFinished: (() -> Void)?

    /// Resolves a positive monotonic deadline before preflight starts.
    init(deadline: RoutingDeadline, observer: ((RoutingAttempt) -> Void)?) throws {
        switch deadline {
        case .after(let duration):
            guard duration > .zero else { throw RoutingRequestError.invalidDeadline }
            cutoff = .now.advanced(by: duration)
        case .unlimited: cutoff = nil
        }
        self.observer = observer
    }

    /// Rejects late provider results before calibration or stream publication.
    func checkActive() throws {
        try Task.checkCancellation()
        if let termination { throw termination }
        if let cutoff, ContinuousClock.now >= cutoff { throw RoutingRequestError.deadlineExceeded }
        guard active else { throw CancellationError() }
    }

    /// Gives elapsed deadlines and caller cancellation precedence when a provider throws before the timer runs.
    func effectiveError(_ providerError: any Error) -> any Error {
        do { try checkActive(); return providerError }
        catch { return error }
    }

    /// Starts timing only an inference operation, not tokenization or unavailable-provider checks.
    func begin(_ route: InferenceRoute) throws {
        try checkActive()
        attempt = (route, .now)
    }

    /// Publishes one outcome while suppressing callbacks from abandoned operations.
    func finishAttempt(_ outcome: RoutingAttempt.Outcome) {
        guard active, let attempt else { return }
        self.attempt = nil
        let event = RoutingAttempt(route: attempt.route, seconds: seconds(since: attempt.started), outcome: outcome)
        attempts.append(event)
        observer?(event)
    }

    /// Terminates the active attempt immediately; future provider completions cannot publish again.
    func terminate(_ error: any Error) {
        guard active else { return }
        termination = error
        finishAttempt((error as? RoutingRequestError) == .deadlineExceeded ? .timedOut : .cancelled)
        active = false
        onAbort?()
        onAbort = nil
    }

    /// Closes a completed request without changing its already-reported attempt outcomes.
    func complete() { active = false; onAbort = nil }

    /// Releases execution ownership only after the provider worker actually exits.
    func workerFinished() {
        onWorkerFinished?()
        onWorkerFinished = nil
    }

    /// Converts monotonic elapsed time into diagnostic seconds.
    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Keeps arbitrary generic results on MainActor while only a Sendable actor reference crosses continuation boundaries.
@MainActor
private final class RoutingActorValue<Value> {
    let value: Value
    /// Stores a result on the same actor as the caller and provider operation.
    init(_ value: Value) { self.value = value }
}

/// Cancels the worker synchronously from any executor, including cancellation before worker registration.
private nonisolated final class RoutingRequestCancellation: Sendable {
    private let state = Mutex<(cancelled: Bool, worker: Task<Void, Never>?)>((false, nil))

    /// Installs the worker or immediately cancels it if the caller already cancelled.
    func register(_ worker: Task<Void, Never>) {
        let cancelled = state.withLock { state in
            if state.cancelled { return true }
            state.worker = worker
            return false
        }
        if cancelled { worker.cancel() }
    }

    /// Marks cancellation before releasing the lock, then invokes task handlers outside the lock.
    func cancel() {
        let worker = state.withLock { state in
            state.cancelled = true
            return state.worker
        }
        worker?.cancel()
    }

    /// Drops the task handle after resolution so an abandoned provider cannot form a retention cycle.
    func clear() { state.withLock { $0.worker = nil } }
}

/// Resolves a request once, returning promptly while asking abandoned provider work to cancel cooperatively.
@MainActor
private final class RoutingRequestGate<Value> {
    private var continuation: CheckedContinuation<RoutingActorValue<Value>, any Error>?
    private var resolved = false
    private var terminalError: (any Error)?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private let context: RoutingRequestContext
    private let cancellation: RoutingRequestCancellation

    /// Binds the gate to the request's deadline and content-free attempt observer.
    init(context: RoutingRequestContext, cancellation: RoutingRequestCancellation) {
        self.context = context
        self.cancellation = cancellation
    }

    /// Handles cancellation arriving before registration without starting provider work.
    func start(_ continuation: CheckedContinuation<RoutingActorValue<Value>, any Error>,
        operation: @escaping @MainActor () async throws -> Value) {
        guard !resolved else {
            context.workerFinished()
            continuation.resume(throwing: terminalError ?? CancellationError())
            return
        }
        self.continuation = continuation
        let worker = Task { @MainActor in
            defer { context.workerFinished() }
            do {
                try context.checkActive()
                let value = try await operation()
                try context.checkActive()
                succeed(value)
            } catch { fail(context.effectiveError(error)) }
        }
        self.worker = worker
        cancellation.register(worker)
        if let cutoff = context.cutoff {
            timer = Task { @MainActor in
                do { try await Task.sleep(until: cutoff, clock: .continuous) }
                catch { return }
                guard !Task.isCancelled else { return }
                fail(RoutingRequestError.deadlineExceeded)
            }
        }
    }

    /// Wins the completion race without transferring a non-Sendable result away from its actor.
    private func succeed(_ value: Value) {
        guard !resolved else { return }
        resolved = true
        context.complete()
        timer?.cancel()
        timer = nil
        worker = nil
        cancellation.clear()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: RoutingActorValue(value))
    }

    /// Wins timeout, cancellation or failure exactly once and suppresses late success.
    func fail(_ error: any Error) {
        guard !resolved else { return }
        resolved = true
        terminalError = error
        context.terminate(error)
        timer?.cancel()
        worker?.cancel()
        timer = nil
        worker = nil
        cancellation.clear()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: error)
    }
}

/// Shares cancellation and deadline behavior between core requests, adapter preflight and streams.
@MainActor
enum RoutingRequestRunner {
    /// Races a monotonic deadline without task-group scope waiting on a noncooperative provider.
    static func run<Value>(context: RoutingRequestContext,
        operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let cancellation = RoutingRequestCancellation()
        let gate = RoutingRequestGate<Value>(context: context, cancellation: cancellation)
        let boxed = try await withTaskCancellationHandler {
            if Task.isCancelled { gate.fail(CancellationError()) }
            return try await withCheckedThrowingContinuation { continuation in
                gate.start(continuation, operation: operation)
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in gate.fail(CancellationError()) }
        }
        try Task.checkCancellation()
        return boxed.value
    }
}
