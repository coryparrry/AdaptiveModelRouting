import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Exercises hard local privacy, bounded deadlines and caller cancellation with adversarial providers.
@MainActor
final class RequestControlTests: XCTestCase {
    /// Holds mutable non-Sendable app data to preserve the original generic response contract.
    private final class AppValue { var text = "value" }

    /// Creates deterministic routers without disk or live network observation.
    private func router(configuration: RoutingConfiguration = .balanced) -> AdaptiveRouter {
        AdaptiveRouter(monitorConnection: false, configuration: configuration, persistence: .memoryOnly)
    }

    /// Local-only policy overrides a contradictory preference and never retries cloud after local failure.
    func testLocalOnlyNeverCallsCloud() async throws {
        for fails in [false, true] {
            var localCalls = 0
            do {
                let result = try await InferenceExecutor.respond(preferred: .cloud, canUseLocalWhole: true, policy: .localOnly,
                    shouldFallback: { _, _ in true }, cloud: { XCTFail("Local-only requests cannot contact cloud."); return "cloud" },
                    onDevice: {
                        localCalls += 1
                        if fails { throw URLError(.timedOut) }
                        return "local"
                    })
                XCTAssertFalse(fails)
                XCTAssertEqual(result, "local")
            } catch let error as URLError { XCTAssertTrue(fails); XCTAssertEqual(error.code, .timedOut) }
            XCTAssertEqual(localCalls, 1)
        }
    }

    /// All policy, availability, capacity and network combinations respect provider eligibility.
    func testPolicyAvailabilityMatrix() async throws {
        for policy in [RoutingPolicy.automatic, .cloudRequired, .localOnly] {
            for localReady in [false, true] {
                for cloudReady in [false, true] {
                    for fits in [false, true] {
                        for offline in [false, true] {
                            let router = router()
                            router.updateConnection(.init(kind: offline ? .offline : .wifi))
                            var routes: [InferenceRoute] = []
                            let result = try await router.respondDetailed(inputTokens: fits ? 100 : 9_000, localContextCapacity: 8_192,
                                policy: policy, availability: .init(onDevice: localReady, cloud: cloudReady),
                                cloud: { routes.append(.cloud); return "cloud" }, onDevice: { routes.append(.onDevice); return "local" })
                            let expected: InferenceRoute?
                            if policy == .cloudRequired { expected = cloudReady ? .cloud : nil }
                            else if policy == .localOnly || offline { expected = localReady && fits ? .onDevice : nil }
                            else if cloudReady { expected = .cloud }
                            else { expected = localReady && fits ? .onDevice : nil }
                            XCTAssertEqual(result.route, expected)
                            XCTAssertEqual(routes, expected.map { [$0] } ?? [])
                            if expected == nil {
                                XCTAssertEqual(result.status, policy != .cloudRequired && localReady && !fits ? .requiresChunking : .unavailable)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A deadline returns before a noncooperative provider completes and prevents late health/training updates.
    func testDeadlineReturnsBeforeProviderAndSuppressesLateResult() async throws {
        let router = router(configuration: .init(slowCloudAfter: .milliseconds(400)))
        let provider = ControlledRoutingProvider()
        var events: [RoutingAttempt] = []
        let safety = Task { try? await Task.sleep(for: .seconds(5)); provider.release() }
        defer { safety.cancel(); provider.release() }
        let request = Task {
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                deadline: .after(.milliseconds(200)), shouldFallback: { _, _ in true }, onAttempt: { events.append($0) },
                cloud: { await provider.call() }, onDevice: { XCTFail("Deadlines must not trigger recovery."); return "local" })
        }
        await provider.started.wait()
        do { _ = try await request.value; XCTFail("The deadline must propagate.") }
        catch RoutingRequestError.deadlineExceeded {}
        XCTAssertFalse(provider.released, "Returning must not wait for ignored cancellation.")
        XCTAssertEqual(events.map(\.outcome), [.timedOut])
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(router.profile.failures.isEmpty, "The abandoned slow watch must be cancelled.")
        provider.release()
        await provider.finished.wait()
        await Task.yield()
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertEqual(events.count, 1)
    }

    /// One deadline covers both the failed cloud operation and local fallback rather than restarting per lane.
    func testDeadlineSpansFallback() async throws {
        let router = router()
        let provider = ControlledRoutingProvider()
        var events: [RoutingAttempt] = []
        let safety = Task { try? await Task.sleep(for: .seconds(5)); provider.release() }
        defer { safety.cancel(); provider.release() }
        let started = ContinuousClock.now
        do {
            let _: RoutingResult<String> = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                deadline: .after(.seconds(1)), onAttempt: { events.append($0) }, cloud: {
                    try await Task.sleep(for: .milliseconds(600))
                    throw URLError(.timedOut)
                }, onDevice: { await provider.call() })
            XCTFail("The shared deadline must stop fallback too.")
        } catch RoutingRequestError.deadlineExceeded {}
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(1_400), "Fallback must use the remaining deadline, not start a new one.")
        XCTAssertFalse(provider.released)
        XCTAssertEqual(events.map(\.route), [.cloud, .onDevice])
        XCTAssertEqual(events.map(\.outcome), [.failed, .timedOut])
        provider.release()
        await provider.finished.wait()
    }

    /// Caller cancellation also returns without waiting for an uncooperative provider.
    func testCallerCancellationReturnsPromptly() async throws {
        let router = router()
        let provider = ControlledRoutingProvider()
        var events: [RoutingAttempt] = []
        let safety = Task { try? await Task.sleep(for: .seconds(5)); provider.release() }
        defer { safety.cancel(); provider.release() }
        let request = Task {
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192, deadline: .unlimited,
                onAttempt: { events.append($0) }, cloud: { await provider.call() },
                onDevice: { XCTFail("Cancellation must not switch models."); return "local" })
        }
        await provider.started.wait()
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancellation must propagate.") }
        catch is CancellationError {}
        XCTAssertFalse(provider.released)
        XCTAssertEqual(events.map(\.outcome), [.cancelled])
        provider.release()
        await provider.finished.wait()
    }

    /// Invalid deadlines fail before provider work, and generic app objects stay on the main actor.
    func testDeadlineValidationAndNonSendableOutput() async throws {
        let router = router()
        do {
            let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192, deadline: .after(.zero),
                cloud: { XCTFail("Invalid deadlines cannot run providers."); return nil }, onDevice: { "local" })
            XCTFail("Invalid deadline must fail.")
        } catch RoutingRequestError.invalidDeadline {}
        let value = AppValue()
        let output = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { value }, onDevice: { value })
        XCTAssertTrue(output === value)
    }
}
