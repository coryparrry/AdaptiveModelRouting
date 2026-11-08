import Foundation
import XCTest

/// Coordinates asynchronous tests without polling or blocking the main actor.
@MainActor
final class RoutingTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until signalled, failing with the caller's location instead of hanging an entire CI stage.
    func wait(timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line) async {
        if signalled { return }
        let timer = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            guard !signalled else { return }
            XCTFail("Expected asynchronous signal did not arrive before the test timeout.", file: file, line: line)
            signal()
        }
        defer { timer.cancel() }
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
