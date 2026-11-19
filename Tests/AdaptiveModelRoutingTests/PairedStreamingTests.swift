import Foundation
import XCTest
import AdaptiveModelRouting

/// Verifies that paired inference never mixes secondary output into a published stream.
@MainActor
final class PairedStreamingTests: XCTestCase {
    /// Produces deterministic cumulative snapshots or a terminal provider error.
    private func source(_ values: [String], error: (any Error)? = nil) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            for value in values { continuation.yield(value) }
            if let error { continuation.finish(throwing: error) }
            else { continuation.finish() }
        }
    }

    /// Background stream snapshots are consumed for timings without becoming visible updates.
    func testOnlySelectedStreamPublishesOutput() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        var updates: [String] = []
        var attempts: [RoutingAttempt] = []
        var cloudCalls = 0
        var localCalls = 0
        for try await event in router.stream(inputTokens: 100, localContextCapacity: 8_192,
            onAttempt: { attempts.append($0) },
            cloud: { cloudCalls += 1; return self.source(["cloud", "cloud answer"]) },
            onDevice: { localCalls += 1; return self.source(["hidden", "hidden local answer"]) }) {
            if case .update(let value, let route) = event {
                updates.append(value)
                XCTAssertEqual(route, .cloud)
            }
            if case .completed(let result) = event {
                XCTAssertEqual(result.value, "cloud answer")
                XCTAssertFalse(result.didFallback)
                XCTAssertEqual(result.attempts.map(\.route), [.cloud])
            }
        }
        await router.waitForCalibration()
        XCTAssertEqual(updates, ["cloud", "cloud answer"])
        XCTAssertEqual(attempts.map(\.route), [.cloud])
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(router.profile.samples.count, 2)
    }

    /// A pre-output cloud failure uses the existing local stream's final snapshot without invoking it again.
    func testStreamingFallbackReusesSecondaryGeneration() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        var localCalls = 0
        var updates: [String] = []
        for try await event in router.stream(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { self.source([], error: URLError(.timedOut)) },
            onDevice: { localCalls += 1; return self.source(["local", "local answer"]) }) {
            if case .update(let value, let route) = event {
                updates.append(value)
                XCTAssertEqual(route, .onDevice)
            }
            if case .completed(let result) = event {
                XCTAssertEqual(result.value, "local answer")
                XCTAssertTrue(result.didFallback)
                XCTAssertEqual(result.attempts.map(\.route), [.cloud, .onDevice])
            }
        }
        await router.waitForCalibration()
        XCTAssertEqual(updates, ["local answer"])
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(router.profile.samples.count, 1)
    }

    /// Failure after a visible cloud snapshot never switches the visible answer to the secondary model.
    func testPartialOutputFailureDoesNotPublishProbe() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        var updates: [String] = []
        do {
            for try await event in router.stream(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { self.source(["partial cloud"], error: URLError(.timedOut)) },
                onDevice: { self.source(["hidden local"]) }) {
                if case .update(let value, let route) = event {
                    updates.append(value)
                    XCTAssertEqual(route, .cloud)
                }
                if case .completed = event { XCTFail("A partial-output error must terminate the stream.") }
            }
            XCTFail("The original error must propagate.")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        await router.waitForCalibration()
        XCTAssertEqual(updates, ["partial cloud"])
    }
}
