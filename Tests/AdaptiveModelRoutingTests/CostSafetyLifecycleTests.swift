import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Pins continued-calibration spending, concurrency and restart behavior beyond single-request matrices.
@MainActor
final class CostSafetyLifecycleTests: XCTestCase {
    /// Creates a healthy local-winning workload whose next request is below the refresh cadence.
    private func scenario() -> CostScenario {
        .init(policy: .automatic, paired: true, training: .localFaster, localReady: true, cloudReady: true,
            offline: false, capacity: 8_192, cloud: .success, local: .success)
    }

    /// A burst of 103 local-winning calls spends no fresh PCC quota before the cloud cooldown expires.
    func testExactContinuedCloudCallBudget() async throws {
        let profiles = try CostProfiles()
        defer { profiles.cleanup() }
        let router = try profiles.router(scenario())
        var cloudCalls = 0
        var localCalls = 0
        for request in 1...103 {
            let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                workload: profiles.workload, cloud: {
                    cloudCalls += 1
                    try await Task.sleep(for: .milliseconds(10))
                    return "cloud"
                }, onDevice: { localCalls += 1; return "local" })
            await router.waitForCalibration()
            XCTAssertEqual(result.route, .onDevice, "Request \(request)")
            XCTAssertFalse(result.didFallback)
            XCTAssertEqual(cloudCalls, 0, "A burst must not bypass the time-based quota cooldown at request \(request)")
            XCTAssertEqual(localCalls, request)
        }
    }

    /// Foreground requests arriving during a blocked cloud probe cannot fan out new secondary cloud calls.
    func testConcurrentRequestsShareOneSecondarySlot() async throws {
        let profiles = try CostProfiles(cloudAge: 601)
        defer { profiles.cleanup() }
        let router = try profiles.router(scenario())
        let cloud = ControlledRoutingProvider()
        defer { cloud.release(); router.cancelCalibration() }
        var cloudCalls = 0
        var localCalls = 0
        for _ in 0..<40 {
            let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                workload: profiles.workload,
                cloud: { cloudCalls += 1; return await cloud.call() },
                onDevice: { localCalls += 1; return "local" })
        }
        await cloud.started.wait()
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(localCalls, 40)
        router.cancelCalibration()
        await router.waitForCalibration()
        for _ in 0..<20 {
            let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                workload: profiles.workload,
                cloud: { cloudCalls += 1; return "unexpected overlapping probe" }, onDevice: { "local" })
        }
        XCTAssertEqual(cloudCalls, 1, "Ignored cancellation must retain the secondary slot.")
        cloud.release()
        await cloud.finished.wait()
        await router.waitForCalibration()
    }

    /// A persisted, valid calibration prevents paying the cold-start cloud cost again after a restart.
    func testRestartReusesSuccessfulPairedCalibration() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let router = AdaptiveRouter(directory: directory, monitorConnection: false)
            for _ in 0..<3 {
                let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                    cloud: { try await Task.sleep(for: .milliseconds(10)); return "cloud" }, onDevice: { "local" })
                await router.waitForCalibration()
            }
            XCTAssertEqual(router.profile.samples.count, 6)
        }
        let restarted = AdaptiveRouter(directory: directory, monitorConnection: false)
        let value: String? = try await restarted.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { XCTFail("A restart with valid evidence must not create a new cold-start request."); return "cloud" },
            onDevice: { "local" })
        await restarted.waitForCalibration()
        XCTAssertEqual(value, "local")
    }

    /// Automatic recovery can contact cloud after local fails offline; only localOnly is a no-cloud budget guarantee.
    func testOfflineRecoveryCostIsExplicitAndLocalOnlyForbidsIt() async throws {
        for policy in [RoutingPolicy.automatic, .localOnly] {
            let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
            router.updateConnection(.init(kind: .offline))
            var cloudCalls = 0
            do {
                let value: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                    policy: policy, cloud: { cloudCalls += 1; return "cloud" }, onDevice: { throw URLError(.timedOut) })
                XCTAssertEqual(policy, .automatic)
                XCTAssertEqual(value, "cloud")
            } catch { XCTAssertEqual(policy, .localOnly) }
            XCTAssertEqual(cloudCalls, policy == .localOnly ? 0 : 1)
        }
    }

    /// Both route previews are pure and never start calibration or change the generation count.
    func testDecisionPreviewsDoNotSpendProviderCalls() async throws {
        let profiles = try CostProfiles()
        defer { profiles.cleanup() }
        let router = try profiles.router(scenario())
        let before = router.profile.samples.count
        for _ in 0..<1_000 {
            _ = router.decision(inputTokens: 100, localCapacity: 8_192, workload: profiles.workload)
            _ = router.choose(inputTokens: 100, localCapacity: 8_192, workload: profiles.workload)
        }
        XCTAssertEqual(router.profile.samples.count, before)
        XCTAssertFalse(router.isCalibrating)
        XCTAssertNil(router.lastCalibrationAttempt)
    }

    /// Thousands of binary-exact timing vectors verify the fastest default against the documented recency weights.
    func testFastestTimingVectorProperty() {
        let values = [0.125, 0.5, 1.0, 4.0]
        let vectors = values.flatMap { a in values.flatMap { b in values.map { [a, b, $0] } } }
        let now = Date.now
        var cases = 0
        for local in vectors {
            for cloud in vectors {
                var profile = PerformanceProfile()
                for index in 0..<3 {
                    let date = now.addingTimeInterval(Double(index - 3))
                    profile.record(model: .onDevice, tokens: 100, seconds: local[index], connection: .init(kind: .wifi), now: date)
                    profile.record(model: .cloud, tokens: 100, seconds: cloud[index], connection: .init(kind: .wifi), now: date)
                }
                let older = exp2(-2.0 / 300)
                let middle = 2 * exp2(-1.0 / 300)
                let expected: InferenceRoute = older * local[0] + middle * local[1] + 4 * local[2]
                    < older * cloud[0] + middle * cloud[1] + 4 * cloud[2] ? .onDevice : .cloud
                XCTAssertEqual(profile.choose(inputTokens: 100, localCapacity: 8_192, connection: .init(kind: .wifi), now: now),
                    expected, "local=\(local), cloud=\(cloud)")
                cases += 1
            }
        }
        XCTAssertEqual(cases, 4_096)
    }
}
