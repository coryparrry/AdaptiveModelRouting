import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Verifies quota pacing with a deterministic clock instead of sleeping or consuming real quota.
final class QuotaScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A successful or failed cloud use must satisfy both elapsed time and the configured request cadence.
    func testExactCadenceAndCooldown() {
        var schedule = RoutingCalibrationSchedule()
        schedule.recordCloudUse(at: now)
        for _ in 0..<1_000 {
            XCTAssertFalse(schedule.shouldProbe(required: false, configuration: .paired(refreshEvery: 10), route: .cloud,
                cloudInterval: 600, now: now.addingTimeInterval(599)))
        }
        XCTAssertTrue(schedule.shouldProbe(required: false, configuration: .paired(refreshEvery: 10), route: .cloud,
            cloudInterval: 600, now: now.addingTimeInterval(600)))
        schedule.resetCadence()
        schedule.recordCloudUse(at: now.addingTimeInterval(600))
        for _ in 0..<9 {
            XCTAssertFalse(schedule.shouldProbe(required: false, configuration: .paired(refreshEvery: 10), route: .cloud,
                cloudInterval: 600, now: now.addingTimeInterval(1_200)))
        }
        XCTAssertTrue(schedule.shouldProbe(required: false, configuration: .paired(refreshEvery: 10), route: .cloud,
            cloudInterval: 600, now: now.addingTimeInterval(1_200)))
    }

    /// Missing/stale timing evidence and repeated cancellation cannot bypass a cloud-use cooldown.
    func testRequiredEvidenceAndCadenceResetCannotSpendEarly() {
        var schedule = RoutingCalibrationSchedule()
        schedule.restoreCloudUse(now)
        for second in 0..<600 {
            schedule.resetCadence()
            XCTAssertFalse(schedule.shouldProbe(required: true, configuration: .paired(refreshEvery: 1), route: .cloud,
                cloudInterval: 600, now: now.addingTimeInterval(Double(second))))
        }
        XCTAssertTrue(schedule.shouldProbe(required: true, configuration: .paired(), route: .cloud,
            cloudInterval: 600, now: now.addingTimeInterval(600)))
    }

    /// Local calibration remains immediate and cannot spend PCC quota even when cloud work is cooling down.
    func testLocalLearningDoesNotWaitForCloudCooldown() {
        var schedule = RoutingCalibrationSchedule()
        schedule.recordCloudUse(at: now)
        for _ in 0..<5 {
            schedule.resetCadence()
            XCTAssertTrue(schedule.shouldProbe(required: true, configuration: .paired(), route: .onDevice,
                cloudInterval: 600, now: now))
        }
    }

    /// Clock rollback is conservative, and a maximum integer cadence cannot overflow under repeated requests.
    func testClockRollbackAndMaximumCadenceAreSafe() {
        var schedule = RoutingCalibrationSchedule()
        schedule.recordCloudUse(at: now)
        XCTAssertFalse(schedule.shouldProbe(required: true, configuration: .paired(), route: .cloud,
            cloudInterval: 600, now: now.addingTimeInterval(-1)))
        for _ in 0..<1_000 {
            XCTAssertFalse(schedule.shouldProbe(required: false, configuration: .paired(refreshEvery: Int.max),
                route: .cloud, cloudInterval: 600, now: now.addingTimeInterval(600)))
        }
        XCTAssertFalse(schedule.shouldProbe(required: true, configuration: .singleProvider, route: .cloud,
            cloudInterval: 600, now: now.addingTimeInterval(600)))
    }
}

/// Ensures quota cooldowns survive failures, normal relaunches and profile/model invalidation.
@MainActor
final class QuotaPersistenceTests: XCTestCase {
    /// The cloud probe that times out cannot repeat on every subsequent request with still-stale evidence.
    func testTimedOutCloudProbeCannotRepeatInRequestBurst() async throws {
        let profiles = try CostProfiles(cloudAge: 601)
        defer { profiles.cleanup() }
        let scenario = CostScenario(policy: .automatic, paired: true, training: .localFaster,
            localReady: true, cloudReady: true, offline: false, capacity: 8_192, cloud: .success, local: .success)
        let router = try profiles.router(scenario, configuration: .init(calibration: .paired(timeout: .milliseconds(20))))
        var cloudCalls = 0
        for _ in 0..<30 {
            let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                workload: profiles.workload, cloud: {
                    cloudCalls += 1
                    try await Task.sleep(for: .milliseconds(100))
                    return "cloud"
                }, onDevice: { "local" })
            XCTAssertEqual(result.route, .onDevice)
            await router.waitForCalibration()
        }
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(router.lastCalibrationAttempt?.outcome, .timedOut)
    }

    /// Already-cancelled standalone measurement cannot start a quota-consuming callback.
    func testStandaloneMeasurementDoesNotDispatchAfterCancellation() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        var calls = 0
        let request = Task {
            try await router.measure(model: .cloud, inputTokens: 100, snapshot: router.snapshot()) {
                calls += 1
                return "cloud"
            }
        }
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled measurement must fail before dispatch.") }
        catch is CancellationError {}
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(router.profile.samples.isEmpty)
    }

    /// A failed foreground operation persists quota pacing despite producing no successful timing observation.
    func testSingleProviderRefreshTimeoutCannotSpendOnEveryRequest() async throws {
        let profiles = try CostProfiles(cloudAge: 601)
        defer { profiles.cleanup() }
        let scenario = CostScenario(policy: .automatic, paired: false, training: .localFaster,
            localReady: true, cloudReady: true, offline: false, capacity: 8_192, cloud: .success, local: .success)
        let router = try profiles.router(scenario, configuration: .init(requestDeadline: .after(.milliseconds(20)),
            calibration: .singleProvider))
        var cloudCalls = 0
        for index in 0..<30 {
            do {
                let value: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                    workload: profiles.workload, cloud: {
                        cloudCalls += 1
                        try await Task.sleep(for: .milliseconds(100))
                        return "cloud"
                    }, onDevice: { "local" })
                XCTAssertGreaterThan(index, 0)
                XCTAssertEqual(value, "local")
            } catch RoutingRequestError.deadlineExceeded { XCTAssertEqual(index, 0) }
        }
        XCTAssertEqual(cloudCalls, 1)
    }

    /// A failed foreground operation persists quota pacing despite producing no successful timing observation.
    func testFailedCloudUseIsPersistedBeforeGenerationAndSurvivesIdentityReset() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        do {
            let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                policy: .cloudRequired, cloud: {
                    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("latency.json"))) as! [String: Any]
                    XCTAssertNotNil(json["lastCloudUse"], "Reserve quota pacing before dispatch, including crashes/errors.")
                    throw URLError(.badURL)
                }, onDevice: { XCTFail("Cloud-required cannot use local."); return "local" })
        } catch let error as URLError { XCTAssertEqual(error.code, .badURL) }
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("latency.json"))) as! [String: Any]
        router.updateCalibrationIdentifier("new-model")
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("latency.json"))) as! [String: Any]
        XCTAssertEqual(before["lastCloudUse"] as? Double, after["lastCloudUse"] as? Double)
        XCTAssertTrue(router.profile.samples.isEmpty)
        var profile = PerformanceProfile()
        for route in [InferenceRoute.cloud, .onDevice] {
            for index in 0..<3 {
                profile.record(model: route, tokens: 100, seconds: route == .cloud ? 4 : 1,
                    connection: .init(kind: .unknown),
                    now: Date.now.addingTimeInterval(Double(index - 3) - (route == .cloud ? 1_000 : 0)))
            }
        }
        var cache = before
        cache["profile"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        try JSONSerialization.data(withJSONObject: cache).write(to: directory.appendingPathComponent("latency.json"))
        let restarted = AdaptiveRouter(directory: directory, monitorConnection: false)
        let value: String? = try await restarted.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { XCTFail("Restored failed-use cooldown must block stale-evidence probing."); return "cloud" },
            onDevice: { "local" })
        await restarted.waitForCalibration()
        XCTAssertEqual(value, "local")
    }
}
