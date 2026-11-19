import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Exercises hard local privacy, bounded deadlines and caller cancellation with adversarial providers.
@MainActor
final class RequestControlTests: XCTestCase {
    /// Holds mutable non-Sendable app data to preserve the original generic response contract.
    private final class AppValue { var text = "value" }

    /// Simulates a structured throttle returned after the request stops waiting.
    private struct Throttle: RoutingRetryAfterProviding {
        let routingRetryAfter: Date?
    }

    /// Keeps the main actor occupied past the cutoff so the request worker must detect expiry itself.
    private func blockPastDeadline() { Thread.sleep(forTimeInterval: 0.25) }

    /// Creates deterministic routers without disk or live network observation.
    private func router(configuration: RoutingConfiguration = .balanced) -> AdaptiveRouter {
        singleProviderRouter(monitorConnection: false, configuration: configuration, persistence: .memoryOnly)
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

    /// A deadline reached during the first cloud pacing write expires without reporting a provider attempt.
    func testDeadlineDuringCloudReservationDoesNotCountAnAttempt() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false,
            configuration: .init(calibration: .singleProvider))
        let cache = directory.appendingPathComponent("latency.json")
        let start = ContinuousClock.now
        var attempts: [RoutingAttempt] = []
        // Move time to the cutoff as soon as the real reservation reaches disk.
        let context = try RoutingRequestContext(deadline: .after(.seconds(1)), now: {
            FileManager.default.fileExists(atPath: cache.path) ? start.advanced(by: .seconds(1)) : start
        }, observer: { attempts.append($0) })
        do {
            _ = try await router.performDetailed(context: context, inputTokens: 100, localContextCapacity: 8_192,
                policy: .cloudRequired, workload: .init(), availability: .init(), shouldFallback: { _, _ in false },
                cloud: { _, _ in XCTFail("Expired reservation reached cloud"); return "cloud" },
                onDevice: { _, _ in XCTFail("Cloud-required request reached local"); return "local" })
            XCTFail("Expected the request deadline")
        } catch RoutingRequestError.deadlineExceeded {}
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any]
        XCTAssertNotNil(saved?["lastCloudUse"])
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertTrue(router.profile.samples.isEmpty)
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

    /// Provider failure after the cutoff is a timeout with no classification, health training or fallback.
    func testErrorAfterCutoffPreservesOnlyTheServerThrottle() async throws {
        let router = router()
        var attempts: [RoutingAttempt] = []
        do {
            let _: RoutingResult<String> = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                deadline: .after(.milliseconds(150)),
                shouldFallback: { _, _ in XCTFail("Expired failures cannot authorize recovery."); return true },
                onAttempt: { attempts.append($0) }, cloud: {
                    self.blockPastDeadline()
                    throw Throttle(routingRetryAfter: .now.addingTimeInterval(3_600))
                }, onDevice: { XCTFail("Deadline must prevent fallback."); return "local" })
            XCTFail("Expected the request deadline.")
        } catch RoutingRequestError.deadlineExceeded {}
        XCTAssertEqual(attempts.map(\.outcome), [.timedOut])
        XCTAssertTrue(router.profile.failures.isEmpty)
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).reason, .cloudBackoff)
    }

    /// An error outside provider measurement still obeys the deadline when preflight occupies the main actor.
    func testPreflightErrorAfterCutoffReportsDeadline() async throws {
        let router = router()
        do {
            let _: String = try await router.withRequest(deadline: .after(.milliseconds(150)), onAttempt: { _ in
                XCTFail("Preflight must not report provider attempts.")
            }) { _ in
                self.blockPastDeadline()
                throw URLError(.badURL)
            }
            XCTFail("Expected the request deadline.")
        } catch RoutingRequestError.deadlineExceeded {}
    }

    /// A late owned-stream throttle survives cancellation of its iterator without training the timed-out request.
    func testOwnedStreamRetainsThrottleAfterDeadline() async throws {
        let router = router()
        let provider = ControlledRoutingProvider()
        let finished = RoutingTestSignal()
        var attempts: [RoutingAttempt] = []
        let context = try RoutingRequestContext(deadline: .after(.milliseconds(150)), observer: { attempts.append($0) })
        context.onWorkerFinished = { finished.signal() }
        let events = AsyncThrowingStream<RoutingStreamEvent<String>, any Error>.makeStream()
        defer { provider.release(); events.continuation.finish() }
        do {
            _ = try await RoutingRequestRunner.run(context: context) {
                try await router.performStreaming(context: context, inputTokens: 100, localContextCapacity: 8_192,
                    policy: .cloudRequired, workload: .init(), availability: .init(),
                    shouldFallback: { _, _ in XCTFail("Expired errors cannot be classified."); return true },
                    continuation: events.continuation, cloud: {
                        RoutingProviderStream { _ in
                            _ = await provider.call()
                            throw Throttle(routingRetryAfter: .now.addingTimeInterval(3_600))
                        }
                    }, onDevice: { XCTFail("Cloud-only request cannot fall back."); return RoutingProviderStream { _ in } })
            }
            XCTFail("Expected the stream deadline.")
        } catch RoutingRequestError.deadlineExceeded {}
        provider.release()
        await finished.wait()
        XCTAssertEqual(attempts.map(\.outcome), [.timedOut])
        XCTAssertTrue(router.profile.failures.isEmpty)
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).reason, .cloudBackoff)
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

    /// Caller cancellation inside a synchronous provider suppresses both its value and unavailable-result fallback.
    func testCallerCancellationInsideProviderCannotTrainOrFallback() async throws {
        for unavailable in [false, true] {
            let router = router()
            var request: Task<RoutingResult<String>, any Error>!
            var events: [RoutingAttempt] = []
            var localCalls = 0
            request = Task {
                try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192, deadline: .unlimited,
                    onAttempt: { events.append($0) }, cloud: {
                        request.cancel()
                        return unavailable ? nil : "cancelled output"
                    }, onDevice: { localCalls += 1; return "local" })
            }
            do { _ = try await request.value; XCTFail("Caller cancellation must propagate.") }
            catch is CancellationError {}
            XCTAssertEqual(events.map(\.outcome), [.cancelled])
            XCTAssertEqual(localCalls, 0)
            XCTAssertTrue(router.profile.samples.isEmpty)
            XCTAssertTrue(router.profile.failures.isEmpty)
        }
    }

    /// A retryable provider error after caller cancellation must not reach classification or another provider.
    func testCallerCancellationBeforeProviderErrorCannotRetry() async throws {
        let router = router()
        var request: Task<RoutingResult<String>, any Error>!
        var events: [RoutingAttempt] = []
        var classifierCalls = 0
        var localCalls = 0
        request = Task {
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192, deadline: .unlimited,
                shouldFallback: { _, _ in classifierCalls += 1; return true }, onAttempt: { events.append($0) },
                cloud: { request.cancel(); throw URLError(.timedOut) },
                onDevice: { localCalls += 1; return "local" })
        }
        do { _ = try await request.value; XCTFail("Caller cancellation must propagate.") }
        catch is CancellationError {}
        XCTAssertEqual(events.map(\.outcome), [.cancelled])
        XCTAssertEqual(classifierCalls, 0)
        XCTAssertEqual(localCalls, 0)
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertTrue(router.profile.failures.isEmpty)
    }

    /// A classifier may cancel its caller, which must suppress subsequent health training and fallback.
    func testCallerCancellationDuringClassificationCannotRetry() async throws {
        let router = router()
        var request: Task<RoutingResult<String>, any Error>!
        var events: [RoutingAttempt] = []
        var localCalls = 0
        request = Task {
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192, deadline: .unlimited,
                shouldFallback: { _, _ in request.cancel(); return true }, onAttempt: { events.append($0) },
                cloud: { throw URLError(.timedOut) }, onDevice: { localCalls += 1; return "local" })
        }
        do { _ = try await request.value; XCTFail("Caller cancellation must propagate.") }
        catch is CancellationError {}
        XCTAssertEqual(events.map(\.outcome), [.failed])
        XCTAssertEqual(localCalls, 0)
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertTrue(router.profile.failures.isEmpty)
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
