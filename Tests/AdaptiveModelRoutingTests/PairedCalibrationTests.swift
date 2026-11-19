import Darwin
import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Exercises paired learning through the public router rather than seeded timing profiles.
@MainActor
final class PairedCalibrationTests: XCTestCase {
    /// Uses short real operations, a bounded probe and caller-controlled sample/cadence requirements.
    private func router(minimum: Int = 3, every: Int = 10, timeout: Duration = .seconds(2),
        cloudRetryInterval: TimeInterval = 0.001) -> AdaptiveRouter {
        AdaptiveRouter(monitorConnection: false,
            configuration: .init(minimumLocalSavingSeconds: 0.001, minimumLocalSavingFraction: 0.1,
                minimumSamples: minimum, cloudRetryInterval: cloudRetryInterval, variabilityAllowance: 0,
                calibration: .paired(refreshEvery: every, timeout: timeout)), persistence: .memoryOnly)
    }

    /// The default public router learns and selects local even when its advantage is less than 350 ms.
    func testUnconfiguredRouterChoosesFasterLocalWithoutMinimumSaving() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        for _ in 0..<3 {
            let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { try await Task.sleep(for: .milliseconds(30)); return "cloud" }, onDevice: { "local" })
            XCTAssertEqual(result.route, .cloud)
            await router.waitForCalibration()
        }
        let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { XCTFail("The faster local provider should be selected."); return "cloud" }, onDevice: { "local" })
        XCTAssertEqual(result.value, "local")
        XCTAssertEqual(result.decision.reason, .localFaster)
    }

    /// Learns both lanes from three real requests while returning cloud until the evidence is sufficient.
    func testColdStartLearnsBothLanesFromThreeRequests() async throws {
        let router = router(cloudRetryInterval: RoutingConfiguration.fastest.cloudRetryInterval)
        var localCalls = 0
        for index in 1...3 {
            let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { try await Task.sleep(for: .milliseconds(30)); return "cloud" },
                onDevice: { localCalls += 1; return "local" })
            XCTAssertEqual(result.value, "cloud")
            XCTAssertEqual(result.attempts.map(\.route), [.cloud])
            XCTAssertFalse(result.didFallback)
            await router.waitForCalibration()
            XCTAssertEqual(router.profile.samples.filter { $0.model == .onDevice }.count, index)
        }
        XCTAssertEqual(localCalls, 3)
        let selected = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { XCTFail("No cloud probe is due yet."); return "cloud" }, onDevice: { "local" })
        XCTAssertEqual(selected.value, "local")
        XCTAssertEqual(selected.decision.reason, .localFaster)
        XCTAssertEqual(router.lastCalibrationAttempt?.outcome, .succeeded)
        XCTAssertFalse(router.isCalibrating)
    }

    /// Rechecks the alternative on the configured cadence and switches when its measured performance improves.
    func testContinuedCalibrationCanSwitchBackToCloud() async throws {
        let router = router(minimum: 1, every: 2, cloudRetryInterval: 0.1)
        var cloudCalls = 0
        let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: {
                cloudCalls += 1
                await router.waitForCalibration()
                // Let the paid cooldown elapse while the first cloud response is still in flight.
                try await Task.sleep(for: .milliseconds(150))
                return "cloud"
            }, onDevice: { "local" })
        await router.waitForCalibration()
        let first = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { XCTFail("Only one eligible request since the last probe."); return "cloud" }, onDevice: { "local" })
        XCTAssertEqual(first.route, .onDevice)
        let second = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { cloudCalls += 1; return "faster cloud" },
            onDevice: {
                await router.waitForCalibration()
                let cloudTimes = router.profile.samples.filter { $0.model == .cloud }.map(\.seconds)
                // The newest local sample outweighs the two older fast ones even on a busy runner.
                let slowLocal = 2 * (try XCTUnwrap(cloudTimes.max()))
                try await Task.sleep(for: .seconds(slowLocal))
                return "slower local"
            })
        XCTAssertEqual(second.route, .onDevice)
        await router.waitForCalibration()
        XCTAssertEqual(cloudCalls, 2)
        let third = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { "faster cloud" }, onDevice: { XCTFail("The learned preference should have changed."); return "local" })
        XCTAssertEqual(third.route, .cloud)
        XCTAssertEqual(third.decision.reason, .cloudPreferred)
    }

    /// The displayed answer completes while an uncooperative secondary model is still running.
    func testForegroundDoesNotWaitForShadow() async throws {
        let router = router()
        let local = ControlledRoutingProvider()
        defer { local.release(); router.cancelCalibration() }
        var attempts: [RoutingAttempt] = []
        let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            onAttempt: { attempts.append($0) },
            cloud: { await local.started.wait(); return "visible cloud" }, onDevice: { await local.call() })
        XCTAssertEqual(result.value, "visible cloud")
        XCTAssertFalse(local.released)
        XCTAssertTrue(router.isCalibrating)
        XCTAssertEqual(attempts.map(\.route), [.cloud])
        local.release("hidden local")
        await router.waitForCalibration()
        XCTAssertEqual(attempts.map(\.route), [.cloud], "Shadow completion must not publish foreground callbacks.")
        XCTAssertEqual(router.profile.samples.count, 2)
    }

    /// A recoverable cloud failure consumes the existing local job exactly once and records one local timing.
    func testFallbackReusesProbe() async throws {
        let router = router()
        let local = ControlledRoutingProvider()
        defer { local.release(); router.cancelCalibration() }
        var localCalls = 0
        var classifications = 0
        let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            shouldFallback: { _, _ in classifications += 1; return true }, cloud: {
                await local.started.wait()
                local.release("recovered")
                throw URLError(.timedOut)
            }, onDevice: { localCalls += 1; return await local.call() })
        await router.waitForCalibration()
        XCTAssertEqual(result.value, "recovered")
        XCTAssertEqual(result.attempts.map(\.route), [.cloud, .onDevice])
        XCTAssertTrue(result.didFallback)
        XCTAssertEqual(classifications, 1)
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(router.profile.samples.filter { $0.model == .onDevice }.count, 1)
    }

    /// A probe expiring in the queue leaves the local provider available to an unlimited request.
    func testQueuedProbeTimeoutAllowsForegroundFallback() async throws {
        let router = router(timeout: .milliseconds(10))
        var localCalls = 0
        let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            deadline: .unlimited, cloud: {
                // Keep the main actor busy so the queued probe cannot start before its cutoff.
                usleep(50_000)
                throw URLError(.networkConnectionLost)
            }, onDevice: { localCalls += 1; return "recovered" })
        await router.waitForCalibration()
        XCTAssertEqual(result.value, "recovered")
        XCTAssertEqual(result.attempts.map(\.route), [.cloud, .onDevice])
        XCTAssertEqual(result.attempts.map(\.outcome), [.failed, .succeeded])
        XCTAssertEqual(localCalls, 1)
        XCTAssertNil(router.lastCalibrationAttempt)
    }

    /// A provider that actually ran and reported a timeout cannot be dispatched a second time.
    func testDispatchedProbeTimeoutDoesNotRepeatProvider() async throws {
        let router = router()
        var localCalls = 0
        var attempts: [RoutingAttempt] = []
        do {
            let _: RoutingResult<String> = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                deadline: .unlimited, onAttempt: { attempts.append($0) }, cloud: {
                    await router.waitForCalibration()
                    throw URLError(.networkConnectionLost)
                }, onDevice: {
                    localCalls += 1
                    throw RoutingRequestError.deadlineExceeded
                })
            XCTFail("The dispatched provider's timeout must reach the caller.")
        } catch RoutingRequestError.deadlineExceeded {}
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(attempts.map(\.route), [.cloud, .onDevice])
        XCTAssertEqual(attempts.map(\.outcome), [.failed, .timedOut])
    }

    /// Shadow failures leave the selected answer intact and apply health backoff without retrying.
    func testShadowFailureDoesNotFailForegroundOrRepeatDuringBackoff() async throws {
        let router = router()
        var localCalls = 0
        var classifications = 0
        let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            shouldFallback: { _, _ in classifications += 1; return true },
            cloud: { "cloud" }, onDevice: { localCalls += 1; throw URLError(.timedOut) })
        await router.waitForCalibration()
        XCTAssertEqual(result.value, "cloud")
        XCTAssertEqual(router.lastCalibrationAttempt?.outcome, .failed)
        XCTAssertEqual(classifications, 1)
        let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { "cloud" }, onDevice: { localCalls += 1; return "local" })
        await router.waitForCalibration()
        XCTAssertEqual(localCalls, 1)
    }

    /// Both failing lanes classify each provider error once, including an already failed shadow used for recovery.
    func testFailedProbeClassificationIsNotDuplicatedByFallback() async throws {
        let router = router()
        let localStarted = RoutingTestSignal()
        var classifications: [InferenceRoute] = []
        do {
            let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                shouldFallback: { route, _ in classifications.append(route); return true },
                cloud: { await localStarted.wait(); throw URLError(.timedOut) },
                onDevice: { localStarted.signal(); throw URLError(.cannotConnectToHost) })
            XCTFail("The provider error must remain visible.")
        } catch let error as URLError { XCTAssertEqual(error.code, .cannotConnectToHost) }
        await router.waitForCalibration()
        XCTAssertEqual(classifications.filter { $0 == .cloud }.count, 1)
        XCTAssertEqual(classifications.filter { $0 == .onDevice }.count, 1)
    }

    /// A secondary deadline bounds ignored cancellation and prevents late output from training the profile.
    func testProbeTimeoutDiscardsLateResult() async throws {
        let router = router(timeout: .milliseconds(30))
        let local = ControlledRoutingProvider()
        var localCalls = 0
        defer { local.release(); router.cancelCalibration() }
        let value: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            deadline: .unlimited, cloud: { await local.started.wait(); return "cloud" },
            onDevice: { localCalls += 1; return await local.call() })
        XCTAssertEqual(value, "cloud")
        await router.waitForCalibration()
        XCTAssertEqual(router.lastCalibrationAttempt?.outcome, .timedOut)
        XCTAssertTrue(router.isCalibrating, "The timed-out provider still occupies its execution slot.")
        XCTAssertFalse(local.released)
        for _ in 0..<3 {
            let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { "cloud" }, onDevice: { localCalls += 1; return "unexpected second probe" })
        }
        XCTAssertEqual(localCalls, 1, "Timeout must not allow more secondary work while the first provider runs.")
        local.release()
        await local.finished.wait()
        await Task.yield()
        await router.waitForCalibration()
        XCTAssertFalse(router.isCalibrating)
        XCTAssertFalse(router.profile.samples.contains { $0.model == .onDevice })
    }

    /// Explicit cancellation also reserves the execution slot until ignored provider work actually stops.
    func testExplicitCancellationRetainsProviderSlot() async throws {
        let router = router()
        let local = ControlledRoutingProvider()
        defer { local.release(); router.cancelCalibration() }
        var localCalls = 0
        let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { await local.started.wait(); return "cloud" },
            onDevice: { localCalls += 1; return await local.call() })
        router.cancelCalibration()
        await router.waitForCalibration()
        XCTAssertTrue(router.isCalibrating)
        let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { "cloud" }, onDevice: { localCalls += 1; return "unexpected second probe" })
        XCTAssertEqual(localCalls, 1)
        local.release()
        await local.finished.wait()
        await Task.yield()
        await router.waitForCalibration()
        XCTAssertFalse(router.isCalibrating)
        XCTAssertFalse(router.profile.samples.contains { $0.model == .onDevice })
        let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { "cloud" }, onDevice: { localCalls += 1; return "new probe after exit" })
        await router.waitForCalibration()
        XCTAssertEqual(localCalls, 2)
    }

    /// An immediate foreground failure cancels an unstarted probe without permanently reserving its slot.
    func testCancellationBeforeProbeStartReleasesSlot() async throws {
        let router = router()
        var localCalls = 0
        do {
            let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { throw URLError(.badURL) }, onDevice: { localCalls += 1; return "local" })
            XCTFail("An invalid request must propagate without fallback.")
        } catch let error as URLError { XCTAssertEqual(error.code, .badURL) }
        await router.waitForCalibration()
        XCTAssertFalse(router.isCalibrating)
        XCTAssertEqual(localCalls, 0)
        let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { "cloud" }, onDevice: { localCalls += 1; return "local" })
        await router.waitForCalibration()
        XCTAssertEqual(localCalls, 1, "A probe cancelled before start must release the slot.")
    }

    /// Cancelling the foreground request also cancels its paired work and suppresses late calibration.
    func testForegroundCancellationCancelsProbe() async throws {
        let router = router()
        let local = ControlledRoutingProvider()
        defer { local.release(); router.cancelCalibration() }
        let request = Task {
            try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { try await Task.sleep(for: .seconds(10)); return "cloud" }, onDevice: { await local.call() })
        }
        await local.started.wait()
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancellation must reach the caller.") }
        catch is CancellationError {}
        await router.waitForCalibration()
        XCTAssertEqual(router.lastCalibrationAttempt?.outcome, .cancelled,
            "Parent cancellation must stop the probe, rather than leave it running until timeout.")
        local.release()
        await local.finished.wait()
        await Task.yield()
        XCTAssertTrue(router.profile.samples.isEmpty)
    }

    /// Profile, connection, model and storage changes invalidate pending secondary work.
    func testLifecycleChangesDiscardPendingProbe() async throws {
        for change in 0..<4 {
            let router = router()
            let local = ControlledRoutingProvider()
            defer { local.release(); router.cancelCalibration() }
            let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { await local.started.wait(); return "cloud" }, onDevice: { await local.call() })
            switch change {
            case 0: try router.resetProfile()
            case 1: router.updateConnection(.init(kind: .cellular))
            case 2: router.updateCalibrationIdentifier("new model")
            default: try router.setPersistence(.memoryOnly)
            }
            local.release()
            await local.finished.wait()
            await Task.yield()
            await router.waitForCalibration()
            XCTAssertFalse(router.isCalibrating)
            XCTAssertFalse(router.profile.samples.contains { $0.model == .onDevice }, "Lifecycle case \(change)")
        }
    }

    /// Overlapping requests cannot create an unbounded number of secondary model calls.
    func testOnlyOneProbeRunsPerRouter() async throws {
        let router = router()
        let local = ControlledRoutingProvider()
        defer { local.release(); router.cancelCalibration() }
        var localCalls = 0
        for _ in 0..<4 {
            let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { await local.started.wait(); return "cloud" },
                onDevice: { localCalls += 1; return await local.call() })
        }
        XCTAssertEqual(localCalls, 1)
        local.release()
        await router.waitForCalibration()
    }

    /// Hard policies, availability, context capacity and offline paths constrain probes as well as foreground calls.
    func testProbeEligibilityMatrix() async throws {
        for policy in [RoutingPolicy.automatic, .cloudRequired, .localOnly] {
            for ready in [false, true] {
                for fits in [false, true] {
                    for offline in [false, true] {
                        let router = router()
                        router.updateConnection(.init(kind: offline ? .offline : .wifi))
                        var calls: [InferenceRoute] = []
                        let _: String? = try await router.respondDetailed(inputTokens: fits ? 100 : 9_000,
                            localContextCapacity: 8_192, policy: policy,
                            availability: .init(onDevice: ready, cloud: ready),
                            cloud: { calls.append(.cloud); return "cloud" },
                            onDevice: { calls.append(.onDevice); return "local" }).value
                        await router.waitForCalibration()
                        if policy == .localOnly || !ready { XCTAssertFalse(calls.contains(.cloud)) }
                        if policy == .cloudRequired || !ready || !fits { XCTAssertFalse(calls.contains(.onDevice)) }
                        if offline && policy != .cloudRequired { XCTAssertFalse(calls.contains(.cloud)) }
                        let paired = policy == .automatic && ready && fits && !offline
                        XCTAssertEqual(calls.count == 2, paired)
                    }
                }
            }
        }
    }
}
