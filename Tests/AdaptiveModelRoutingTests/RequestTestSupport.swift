import Foundation

/// Coordinates asynchronous tests without polling or blocking the main actor.
@MainActor
final class RoutingTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until signalled, including when the signal arrived before registration.
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Resumes all registered waiters once.
    func signal() {
        guard !signalled else { return }
        signalled = true
        let waiters = waiters
        self.waiters = []
        for waiter in waiters { waiter.resume() }
    }
}

/// Simulates a provider that deliberately ignores task cancellation until explicitly released.
@MainActor
final class ControlledRoutingProvider {
    let started = RoutingTestSignal()
    let finished = RoutingTestSignal()
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var released = false

    /// Suspends without cancellation cooperation to exercise prompt deadline return and late-result suppression.
    func call() async -> String {
        defer { finished.signal() }
        if released { return "late result" }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.signal()
        }
    }

    /// Releases the simulated provider and makes cleanup deterministic.
    func release(_ result: String = "late result") {
        guard !released else { return }
        released = true
        started.signal()
        continuation?.resume(returning: result)
        continuation = nil
    }
}
