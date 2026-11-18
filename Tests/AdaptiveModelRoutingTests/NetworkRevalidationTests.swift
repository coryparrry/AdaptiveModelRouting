import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Verifies cloud revalidation costs and eventual detection without wall-clock waits or model calls.
@MainActor
final class NetworkRevalidationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let wifi = PerformanceProfile.Connection(kind: .wifi)

    /// Creates qualified local evidence independently of the current cloud network.
    private func localProfile(count: Int = 3) -> PerformanceProfile {
        var profile = PerformanceProfile()
        for index in 0..<count {
            profile.record(model: .onDevice, tokens: 100, seconds: 1, connection: wifi,
                now: base.addingTimeInterval(Double(index - count - 20)))
        }
        return profile
    }

    /// Partial cloud evidence, whether faster or slower, cannot trigger a foreground relearning burst.
    func testPartialEvidenceMatrixAndPolicies() {
        for minimum in [1, 3, 5] {
            for count in 0..<minimum {
                for seconds in [0.1, 1, 10.0] {
                    var profile = localProfile(count: minimum)
                    let config = RoutingConfiguration(minimumSamples: minimum)
                    for index in 0..<count {
                        profile.record(model: .cloud, tokens: 100, seconds: seconds, connection: wifi,
                            now: base.addingTimeInterval(Double(index - count)))
                    }
                    let result = profile.decision(inputTokens: 100, localCapacity: 8_192,
                        connection: wifi, now: base, configuration: config)
                    XCTAssertEqual(result.route, .onDevice)
                    XCTAssertEqual(result.reason, .insufficientEvidence)
                    XCTAssertEqual(result.localEstimate?.sampleCount, minimum)
                    XCTAssertNil(result.cloudEstimate)
                    XCTAssertEqual(profile.decision(inputTokens: 100, localCapacity: 8_192,
                        connection: wifi, now: base, configuration: .init(minimumSamples: minimum,
                            calibration: .singleProvider)).route, .cloud)
                    XCTAssertEqual(profile.decision(inputTokens: 100, localCapacity: 8_192,
                        connection: wifi, now: base, configuration: config, policy: .cloudRequired).route, .cloud)
                    XCTAssertEqual(profile.decision(inputTokens: 100, localCapacity: 499,
                        connection: wifi, now: base, configuration: config).route, .cloud)
                    XCTAssertEqual(profile.decision(inputTokens: 100, localCapacity: 8_192,
                        connection: wifi, now: base, configuration: config,
                        availability: .init(onDevice: false)).route, .cloud)
                }
            }
        }
    }

    /// A real cloud improvement is learned through three due probes, with no cloud burst after invalidation.
    func testDefaultPacingEventuallyDetectsFasterCloudAndPreservesSlowerCloud() {
        for cloudSeconds in [0.1, 10.0] {
            var profile = localProfile()
            var schedule = RoutingCalibrationSchedule()
            schedule.recordCloudUse(at: base)
            profile.changedConnection(wifi)
            var probes: [Int] = []
            for second in 0...1_800 {
                let now = base.addingTimeInterval(Double(second))
                let decision = profile.decision(inputTokens: 100, localCapacity: 8_192,
                    connection: wifi, now: now)
                XCTAssertEqual(decision.route, .onDevice, "Only qualified cloud evidence may change foreground.")
                let required = profile.needsCalibration(inputTokens: 100, localCapacity: 8_192,
                    connection: wifi, now: now, configuration: .fastest, policy: .automatic,
                    workload: .init(), availability: .init(), decision: decision)
                if schedule.shouldProbe(required: required, configuration: .paired(), route: .cloud,
                    cloudInterval: 600, now: now) {
                    probes.append(second)
                    schedule.recordCloudUse(at: now)
                    profile.record(model: .cloud, tokens: 100, seconds: cloudSeconds, connection: wifi, now: now)
                }
                profile.record(model: .onDevice, tokens: 100, seconds: 1, connection: wifi, now: now)
            }
            XCTAssertEqual(probes, [600, 1_200, 1_800])
            let learned = profile.decision(inputTokens: 100, localCapacity: 8_192,
                connection: wifi, now: base.addingTimeInterval(1_801))
            XCTAssertEqual(learned.route, cloudSeconds < 1 ? .cloud : .onDevice)
            XCTAssertNotNil(learned.cloudEstimate)
        }
    }

    /// Wrong-size, expired, future and old-network evidence cannot promote unqualified cloud timings.
    func testIncomparableEvidenceAndColdLocalCannotPretendToBeQualified() throws {
        for (tokens, connection, date) in [(1_000, wifi, base.addingTimeInterval(-3)),
            (100, PerformanceProfile.Connection(kind: .cellular), base.addingTimeInterval(-3)),
            (100, wifi, base.addingTimeInterval(-700_000)),
            (100, wifi, base.addingTimeInterval(100))] {
            var cloud = PerformanceProfile()
            for index in 0..<3 {
                cloud.record(model: .cloud, tokens: tokens, seconds: 0.01,
                    connection: connection, now: date.addingTimeInterval(Double(index)))
            }
            var fixture = try JSONSerialization.jsonObject(with: JSONEncoder().encode(localProfile())) as! [String: Any]
            let cloudFixture = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cloud)) as! [String: Any]
            fixture["samples"] = (fixture["samples"] as! [[String: Any]]) + (cloudFixture["samples"] as! [[String: Any]])
            let profile = try JSONDecoder().decode(PerformanceProfile.self,
                from: JSONSerialization.data(withJSONObject: fixture))
            XCTAssertEqual(profile.samples.count, 6, "Ineligible cloud samples must exist when selection runs.")
            let result = profile.decision(inputTokens: 100, localCapacity: 8_192, connection: wifi, now: base)
            XCTAssertEqual(result.route, .onDevice)
            XCTAssertEqual(result.localEstimate?.sampleCount, 3)
            XCTAssertNil(result.cloudEstimate)
            XCTAssertEqual(profile.choose(inputTokens: 1_000, localCapacity: 8_192,
                connection: wifi, now: base), .cloud, "Unqualified local sizes still need cold learning.")
        }
        XCTAssertEqual(localProfile(count: 2).choose(inputTokens: 100, localCapacity: 8_192,
            connection: wifi, now: base), .cloud)
    }

    /// Slower and failed due probes cannot turn invalidated cloud history into repeated paid work.
    func testDueProbeAfterResetCannotBecomeForegroundBurst() async throws {
        for fails in [false, true] {
            let profiles = try CostProfiles(cloudAge: 601)
            defer { profiles.cleanup() }
            let scenario = CostScenario(policy: .automatic, paired: true, training: .localFaster,
                localReady: true, cloudReady: true, offline: false, capacity: 8_192, cloud: .success, local: .success)
            let router = try profiles.router(scenario)
            router.updateConnection(wifi)
            var cloudCalls = 0
            for _ in 0..<30 {
                let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                    workload: profiles.workload, cloud: {
                        cloudCalls += 1
                        if fails { throw URLError(.networkConnectionLost) }
                        try await Task.sleep(for: .milliseconds(5))
                        return "cloud"
                    }, onDevice: { "local" })
                XCTAssertEqual(result.route, .onDevice)
                XCTAssertEqual(result.value, "local")
                await router.waitForCalibration()
            }
            XCTAssertEqual(cloudCalls, 1)
            XCTAssertEqual(router.profile.samples.filter { $0.model == .cloud }.count, fails ? 0 : 1)
        }
    }

    /// Ordered same-coarse resets, concurrent traffic and relaunch preserve the persisted PCC cooldown.
    func testResetBurstAndRelaunchDoNotSpendCloudQuota() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var profile = PerformanceProfile()
        for index in 0..<3 {
            profile.record(model: .onDevice, tokens: 100, seconds: 1, connection: wifi,
                now: Date.now.addingTimeInterval(Double(index - 3)))
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        let cache: [String: Any] = ["version": 1, "system": "network-test", "profile": encoded,
            "lastCloudUse": Date.now.timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: cache).write(to: directory.appendingPathComponent("latency.json"))
        var cloudCalls = 0
        for _ in 0..<2 {
            let router = AdaptiveRouter(directory: directory, system: "network-test", monitorConnection: false)
            router.updateConnection(wifi)
            router.updateConnection(wifi)
            var requests: [Task<RoutingResult<String>, any Error>] = []
            for _ in 0..<30 {
                requests.append(Task { @MainActor in
                    try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                        cloud: { cloudCalls += 1; return "cloud" }, onDevice: { "local" })
                })
            }
            for request in requests {
                let result = try await request.value
                XCTAssertEqual(result.route, .onDevice)
                XCTAssertEqual(result.value, "local")
            }
            await router.waitForCalibration()
            XCTAssertEqual(cloudCalls, 0)
        }
    }
}
