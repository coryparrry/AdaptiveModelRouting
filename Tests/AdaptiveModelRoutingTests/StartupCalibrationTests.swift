import Foundation
import Network
import XCTest
@testable import AdaptiveModelRouting

/// Verifies that native startup spends no optional cloud quota before admitted live local work.
@MainActor
final class StartupCalibrationTests: XCTestCase {
    /// Keeps a provider failure distinct from cancellation and routing deadlines.
    private enum Failure: Error { case permanent }

    /// Restores qualified local history and an expired cloud-use cooldown without making model calls.
    private func fixture(monitoring: Bool = true, nativeObserved: Bool = true) throws -> (AdaptiveRouter, URL, Double) {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var profile = PerformanceProfile()
        let now = Date.now
        for index in 0..<3 {
            profile.record(model: .onDevice, tokens: 100, seconds: 0.3,
                connection: .init(kind: .wifi), now: now.addingTimeInterval(Double(index - 4)))
        }
        let use = now.addingTimeInterval(-1_200).timeIntervalSinceReferenceDate
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        try JSONSerialization.data(withJSONObject: ["version": 1, "system": "startup-test",
            "profile": encoded, "lastCloudUse": use]).write(to: directory.appendingPathComponent("latency.json"))
        let router = AdaptiveRouter(directory: directory, system: "startup-test", monitorConnection: monitoring)
        // Future ordering stamps isolate synthetic unit delivery from the Mac's real queued native callbacks.
        let observedAt = ContinuousClock.now.advanced(by: .seconds(60))
        if monitoring && nativeObserved { router.receiveNativePath(NWPathMonitor().currentPath, observedAt: observedAt) }
        router.updateConnection(.init(kind: nativeObserved ? .wifi : .unknown), observedAt: observedAt)
        return (router, directory, use)
    }

    /// Startup deferral blocks only paid secondary work and does not reserve cloud use before dispatch.
    func testStartupCloudProbeRequiresAdmittedLocalObservation() {
        let coordinator = RoutingCalibrationCoordinator(awaitStartupObservations: true)
        let now = Date.now
        coordinator.recordConnectionObservation()
        for _ in 0..<20 {
            XCTAssertFalse(coordinator.shouldProbe(required: true, configuration: .paired(), route: .cloud,
                cloudInterval: 600, now: now))
        }
        XCTAssertTrue(coordinator.shouldProbe(required: true, configuration: .paired(), route: .onDevice,
            cloudInterval: 600, now: now))
        XCTAssertNil(coordinator.lastCloudUse)
        coordinator.recordLocalObservation()
        XCTAssertTrue(coordinator.shouldProbe(required: true, configuration: .paired(), route: .cloud,
            cloudInterval: 600, now: now))
        XCTAssertNil(coordinator.lastCloudUse)
        coordinator.recordCloudUse(at: now)
        coordinator.cancel()
        XCTAssertFalse(coordinator.awaitsStartupLocalObservation)
        XCTAssertFalse(coordinator.shouldProbe(required: true, configuration: .paired(), route: .cloud,
            cloudInterval: 600, now: now.addingTimeInterval(599)))
        XCTAssertTrue(coordinator.shouldProbe(required: true, configuration: .paired(), route: .cloud,
            cloudInterval: 600, now: now.addingTimeInterval(600)))
    }

    /// Ineligible startup requests do not consume normal probe cadence or alter quota cooldown metadata.
    func testDeferredRequestsDoNotConsumeCadence() {
        let coordinator = RoutingCalibrationCoordinator(awaitStartupObservations: true)
        coordinator.recordConnectionObservation()
        for _ in 0..<20 {
            XCTAssertFalse(coordinator.shouldProbe(required: false, configuration: .paired(refreshEvery: 10), route: .cloud,
                cloudInterval: 600))
        }
        coordinator.recordLocalObservation()
        for _ in 0..<9 {
            XCTAssertFalse(coordinator.shouldProbe(required: false, configuration: .paired(refreshEvery: 10), route: .cloud,
                cloudInterval: 600))
        }
        XCTAssertTrue(coordinator.shouldProbe(required: false, configuration: .paired(refreshEvery: 10), route: .cloud,
            cloudInterval: 600))
        XCTAssertNil(coordinator.lastCloudUse)
    }

    /// A monitored owner answers its first cached-local request without an optional paid callback.
    func testMonitoredStartupReturnsLocalBeforeOptionalCloudWork() async throws {
        let (router, directory, use) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
        var cloudCalls = 0
        let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { cloudCalls += 1; return "cloud" }, onDevice: { "local" })
        await router.waitForCalibration()
        XCTAssertEqual(result.route, .onDevice)
        XCTAssertEqual(result.value, "local")
        XCTAssertEqual(cloudCalls, 0)
        XCTAssertFalse(router.isStartupCloudCalibrationDeferred)
        let cache = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("latency.json"))) as! [String: Any]
        XCTAssertEqual(cache["lastCloudUse"] as? Double, use)
    }

    /// A fast local response cannot unlock paid probing while the initial native observation is pending.
    func testDelayedNativeObservationCannotStartPaidProbe() async throws {
        let (router, directory, _) = try fixture(nativeObserved: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var cloudCalls = 0
        for _ in 0..<2 {
            _ = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { cloudCalls += 1; return "cloud" }, onDevice: { "local" })
            await router.waitForCalibration()
            XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
        }
        XCTAssertEqual(cloudCalls, 0)
        router.receiveNativePath(NWPathMonitor().currentPath,
            observedAt: ContinuousClock.now.advanced(by: .seconds(30)))
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred, "A stale native delivery cannot open startup")
        let observedAt = ContinuousClock.now.advanced(by: .seconds(120))
        router.receiveNativePath(NWPathMonitor().currentPath, observedAt: observedAt)
        router.updateConnection(.init(kind: .wifi), observedAt: observedAt)
        XCTAssertFalse(router.isStartupCloudCalibrationDeferred)
        _ = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { cloudCalls += 1; return "cloud" }, onDevice: { "local" })
        await router.waitForCalibration()
        XCTAssertEqual(cloudCalls, 1)
    }

    /// An explicit accepted known connection prevents startup from waiting forever for a superseded native callback.
    func testKnownManualConnectionCanCompleteStartupReadiness() async throws {
        let (router, directory, _) = try fixture(nativeObserved: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await router.measure(model: .onDevice, inputTokens: 100, snapshot: router.snapshot(), operation: { "local" })
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
        router.updateConnection(.init(kind: .wifi), observedAt: ContinuousClock.now.advanced(by: .seconds(120)))
        XCTAssertFalse(router.isStartupCloudCalibrationDeferred)
        var cloudCalls = 0
        _ = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { cloudCalls += 1; return "cloud" }, onDevice: { "local" })
        await router.waitForCalibration()
        XCTAssertEqual(cloudCalls, 1)
    }

    /// A public availability predicate cannot admit a sample after replacing its measurement identity.
    func testAvailabilityPredicateCannotAdmitResetIdentity() async throws {
        let (router, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await router.measure(model: .onDevice, inputTokens: 100, snapshot: router.snapshot(), available: { _ in
            router.updateCalibrationIdentifier("predicate-reset"); return true
        }, operation: { "stale" })
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
    }

    /// A public availability predicate cannot turn cancellation into startup or timing permission.
    func testAvailabilityPredicateCannotAdmitCancellation() async throws {
        let (router, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = router.profile.samples.count
        let task = Task { @MainActor in
            try await router.measure(model: .onDevice, inputTokens: 100, snapshot: router.snapshot(), available: { _ in
                withUnsafeCurrentTask { $0?.cancel() }; return true
            }, operation: { "cancelled" })
        }
        do { _ = try await task.value; XCTFail("Predicate cancellation must propagate") }
        catch is CancellationError {}
        XCTAssertEqual(router.profile.samples.count, before)
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
    }

    /// Explicitly unmonitored integrations retain their existing immediate secondary calibration behavior.
    func testUnmonitoredOwnerRetainsImmediateProbe() async throws {
        let (router, directory, _) = try fixture(monitoring: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(router.isStartupCloudCalibrationDeferred)
        var cloudCalls = 0
        _ = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { cloudCalls += 1; return "cloud" }, onDevice: { "local" })
        await router.waitForCalibration()
        XCTAssertEqual(cloudCalls, 1)
    }

    /// A failed local operation does not grant paid startup permission to the next request.
    func testLocalFailureKeepsStartupDeferred() async throws {
        let (router, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var cloudCalls = 0
        do {
            let _: RoutingResult<String> = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                shouldFallback: { _, _ in false }, cloud: { cloudCalls += 1; return "cloud" },
                onDevice: { throw Failure.permanent })
            XCTFail("The permanent local failure must propagate")
        } catch Failure.permanent {}
        await router.waitForCalibration()
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
        _ = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { cloudCalls += 1; return "cloud" }, onDevice: { "local" })
        await router.waitForCalibration()
        XCTAssertFalse(router.isStartupCloudCalibrationDeferred)
        XCTAssertEqual(cloudCalls, 0)
    }

    /// A timed-out local worker cannot open startup calibration after its request has ended.
    func testDeadlineKeepsStartupDeferred() async throws {
        let (router, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var cloudCalls = 0
        do {
            let _: RoutingResult<String> = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                deadline: .after(.milliseconds(20)), cloud: { cloudCalls += 1; return "cloud" }, onDevice: {
                    try await Task.sleep(for: .seconds(60)); return "late"
                })
            XCTFail("The deadline must throw")
        } catch { XCTAssertTrue(error is RoutingRequestError || error is CancellationError) }
        await router.waitForCalibration()
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
        XCTAssertEqual(cloudCalls, 0)
    }

    /// Cancellation before local admission cannot authorize subsequent paid startup work.
    func testCancellationKeepsStartupDeferred() async throws {
        let (router, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var release: CheckedContinuation<Void, Never>?
        var cloudCalls = 0
        let task = Task { @MainActor in
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { cloudCalls += 1; return "cloud" }, onDevice: {
                    await withCheckedContinuation { release = $0 }; return "late"
                })
        }
        while release == nil { await Task.yield() }
        task.cancel(); release?.resume()
        do { _ = try await task.value; XCTFail("The cancellation must throw") }
        catch is CancellationError {}
        await router.waitForCalibration()
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
        XCTAssertEqual(cloudCalls, 0)
    }

    /// Empty, zero-token and stale-identity measurements cannot count as admitted startup evidence.
    func testRejectedLocalMeasurementsKeepStartupDeferred() async throws {
        let (router, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let _: String? = try await router.measure(model: .onDevice, inputTokens: 100, snapshot: router.snapshot(),
            available: { $0 != nil }, operation: { nil })
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
        _ = try await router.measure(model: .onDevice, inputTokens: 0, snapshot: router.snapshot(), operation: { "invalid" })
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
        _ = try await router.measure(model: .onDevice, inputTokens: 100, snapshot: router.snapshot(), operation: {
            router.updateCalibrationIdentifier("replacement"); return "stale"
        })
        XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
    }

    /// Forced and recovery cloud work remains available while only optional startup spending is deferred.
    func testRequiredAndRecoveryCloudWorkRemainAvailable() async throws {
        for required in [true, false] {
            let (router, directory, _) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            var cloudCalls = 0
            let result: RoutingResult<String> = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                policy: required ? .cloudRequired : .automatic, shouldFallback: { _, _ in true },
                cloud: { cloudCalls += 1; return "cloud" }, onDevice: { throw Failure.permanent })
            await router.waitForCalibration()
            XCTAssertEqual(result.route, .cloud)
            XCTAssertEqual(cloudCalls, 1)
            XCTAssertTrue(router.isStartupCloudCalibrationDeferred)
        }
    }
}
