import Foundation
import XCTest
import AdaptiveModelRouting

/// Covers streaming recovery boundaries, bounded snapshots, deadlines and consumer cancellation.
@MainActor
final class StreamingTests: XCTestCase {
    /// Creates a router with no model services, disk or network monitor.
    private func router() -> AdaptiveRouter { AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly) }

    /// Creates deterministic cumulative provider snapshots and an optional terminal failure.
    private func source(_ values: [String], error: (any Error)? = nil) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish(throwing: error)
        }
    }

    /// A failure before output may recover locally, with actual route and both attempts preserved.
    func testFallbackBeforeFirstSnapshot() async throws {
        let router = router()
        var values: [String] = []
        var completed: RoutingResult<String>?
        for try await event in router.stream(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { self.source([], error: URLError(.timedOut)) }, onDevice: { self.source(["lo", "local"]) }) {
            switch event {
            case .selected: break
            case .update(let value, let route): values.append(value); XCTAssertEqual(route, .onDevice)
            case .completed(let result): completed = result
            }
        }
        XCTAssertEqual(values, ["lo", "local"])
        XCTAssertEqual(completed?.value, "local")
        XCTAssertEqual(completed?.attempts.map(\.outcome), [.failed, .succeeded])
        XCTAssertEqual(completed?.didFallback, true)
        XCTAssertEqual(router.profile.samples.map(\.model), [.onDevice])
    }

    /// Once output is visible, even a recoverable failure must propagate without another model's output.
    func testNoFallbackAfterPublishedSnapshotButHealthStillRecorded() async throws {
        let router = router()
        var localCalls = 0
        var classifications = 0
        var values: [String] = []
        do {
            for try await event in router.stream(inputTokens: 100, localContextCapacity: 8_192,
                shouldFallback: { _, _ in classifications += 1; return true },
                cloud: { self.source(["partial"], error: URLError(.timedOut)) },
                onDevice: { localCalls += 1; return self.source(["wrong provider"]) }) {
                if case .update(let value, let route) = event { values.append(value); XCTAssertEqual(route, .cloud) }
                if case .completed = event { XCTFail("A failed partial stream cannot report success.") }
            }
            XCTFail("The native error must propagate after partial output.")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertEqual(values, ["partial"])
        XCTAssertEqual(localCalls, 0)
        XCTAssertEqual(classifications, 1)
        XCTAssertEqual(router.profile.failures.map(\.model), [.cloud])
        XCTAssertTrue(router.profile.samples.isEmpty)
    }

    /// Local-only and cloud-required streaming never relax their hard provider constraints.
    func testStreamingHardPolicies() async throws {
        for policy in [RoutingPolicy.localOnly, .cloudRequired] {
            let router = router()
            var routes: [InferenceRoute] = []
            var result: RoutingResult<String>?
            for try await event in router.stream(inputTokens: 100, localContextCapacity: 8_192, policy: policy,
                cloud: { routes.append(.cloud); return self.source(["cloud"]) },
                onDevice: { routes.append(.onDevice); return self.source(["local"]) }) {
                if case .completed(let value) = event { result = value }
            }
            XCTAssertEqual(routes, [policy == .localOnly ? .onDevice : .cloud])
            XCTAssertEqual(result?.route, routes.first)
        }
    }

    /// Empty cloud streams can recover, but empty local-only streams surface a clear no-output error.
    func testEmptyStreamsDoNotPretendSuccess() async throws {
        let router = router()
        var result: RoutingResult<String>?
        for try await event in router.stream(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { self.source([]) }, onDevice: { self.source(["local"]) }) {
            if case .completed(let value) = event { result = value }
        }
        XCTAssertEqual(result?.value, "local")
        do {
            for try await _ in router.stream(inputTokens: 100, localContextCapacity: 8_192, policy: .localOnly,
                cloud: { XCTFail("Local-only cannot recover to cloud."); return self.source(["cloud"]) },
                onDevice: { self.source([]) }) {}
            XCTFail("An empty local stream must fail explicitly.")
        } catch RoutingRequestError.emptyStream {}
    }

    /// Finishing after many snapshots retains bounded events and the final full value.
    func testSnapshotBufferIsBoundedAndFinalValueSurvives() async throws {
        let router = router()
        let finished = RoutingTestSignal()
        let stream = router.stream(inputTokens: 100, localContextCapacity: 8_192,
            onAttempt: { if $0.outcome == .succeeded { finished.signal() } },
            cloud: { self.source((0..<500).map { "snapshot-\($0)" }) }, onDevice: { self.source([]) })
        await finished.wait()
        var events = 0
        var result: RoutingResult<String>?
        for try await event in stream {
            events += 1
            if case .completed(let value) = event { result = value }
        }
        XCTAssertLessThanOrEqual(events, 9)
        XCTAssertEqual(result?.value, "snapshot-499")
        XCTAssertEqual(router.profile.samples.count, 1)
    }

    /// A stalled stream obeys its deadline and cancellation reaches its provider iterator.
    func testStreamDeadlineStopsProvider() async throws {
        let router = router()
        let (source, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let stopped = RoutingTestSignal()
        continuation.onTermination = { _ in Task { @MainActor in stopped.signal() } }
        let safety = Task { try? await Task.sleep(for: .seconds(1)); continuation.finish(); stopped.signal() }
        defer { safety.cancel(); continuation.finish() }
        var events: [RoutingAttempt] = []
        do {
            for try await _ in router.stream(inputTokens: 100, localContextCapacity: 8_192, deadline: .after(.milliseconds(20)),
                onAttempt: { events.append($0) }, cloud: { source }, onDevice: { XCTFail("A deadline cannot switch models."); return self.source([]) }) {}
            XCTFail("The deadline must end the stream.")
        } catch RoutingRequestError.deadlineExceeded {}
        await stopped.wait()
        XCTAssertEqual(events.map(\.outcome), [.timedOut])
        XCTAssertTrue(router.profile.samples.isEmpty)
    }

    /// Cancelling the consuming task stops provider work and does not publish a completed result.
    func testConsumerCancellationStopsProvider() async throws {
        let router = router()
        let (source, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let seen = RoutingTestSignal()
        let stopped = RoutingTestSignal()
        var events: [RoutingAttempt] = []
        continuation.onTermination = { _ in Task { @MainActor in stopped.signal() } }
        let safety = Task { try? await Task.sleep(for: .seconds(1)); seen.signal(); continuation.finish(); stopped.signal() }
        defer { safety.cancel(); continuation.finish() }
        let consumer = Task {
            for try await event in router.stream(inputTokens: 100, localContextCapacity: 8_192, onAttempt: { events.append($0) },
                cloud: { source }, onDevice: { XCTFail("Cancelled output cannot switch models."); return self.source([]) }) {
                if case .update = event { seen.signal() }
                if case .completed = event { XCTFail("Consumer cancellation cannot report completion.") }
            }
        }
        continuation.yield("partial")
        await seen.wait()
        consumer.cancel()
        _ = try? await consumer.value
        await stopped.wait()
        XCTAssertEqual(events.map(\.outcome), [.cancelled])
        XCTAssertTrue(router.profile.samples.isEmpty)
    }
}
