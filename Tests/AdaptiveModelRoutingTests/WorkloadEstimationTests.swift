import Foundation
import XCTest
import AdaptiveModelRouting

/// Checks that workload metadata and timing variability constrain learned lane preferences.
final class WorkloadEstimationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let wifi = PerformanceProfile.Connection(kind: .wifi)

    /// Produces three observations per lane with independently supplied response latencies.
    private func trained(
        local: [Double] = [1, 1, 1], cloud: [Double] = [4, 4, 4],
        workload: RoutingWorkload = .init()
    ) -> PerformanceProfile {
        var profile = PerformanceProfile()
        for index in 0..<3 {
            let date = now.addingTimeInterval(Double(index - 3))
            profile.record(model: .onDevice, tokens: 1_000, seconds: local[index],
                connection: wifi, now: date, workload: workload)
            profile.record(model: .cloud, tokens: 1_000, seconds: cloud[index],
                connection: wifi, now: date, workload: workload)
        }
        return profile
    }

    /// Long, short and unspecified responses cannot borrow one another's timing evidence.
    func testExpectedOutputSeparatesTimingHistory() {
        let profile = trained(workload: .init(expectedOutputTokens: 100))
        for output in [80, 100, 125] {
            XCTAssertEqual(profile.choose(inputTokens: 1_000, localCapacity: 8_192, connection: wifi, now: now,
                workload: .init(expectedOutputTokens: output)), .onDevice)
        }
        for output: Int? in [nil, 0, 1_000] {
            XCTAssertEqual(profile.choose(inputTokens: 1_000, localCapacity: 8_192, connection: wifi, now: now,
                workload: .init(expectedOutputTokens: output)), .cloud)
        }
    }

    /// Cloud session reuse cannot supply fresh-session estimates, and local reuse requires new calibration.
    func testSessionStatesAreComparedPerProvider() {
        var profile = trained(workload: .init(cloudSession: .reused))
        XCTAssertEqual(profile.choose(inputTokens: 1_000, localCapacity: 8_192, connection: wifi, now: now,
            workload: .init(cloudSession: .reused)), .onDevice)
        XCTAssertEqual(profile.choose(inputTokens: 1_000, localCapacity: 8_192, connection: wifi, now: now), .cloud)
        let reused = RoutingWorkload(localSession: .reused, cloudSession: .reused)
        profile.record(model: .onDevice, tokens: 1_000, seconds: 0.1, connection: wifi, now: now, workload: reused)
        XCTAssertEqual(profile.choose(inputTokens: 1_000, localCapacity: 8_192, connection: wifi, now: now,
            workload: reused), .cloud, "One reused local session is not three comparable observations.")
    }

    /// A mean advantage is insufficient when either provider's recent latency has a wide spread.
    func testVariableLatencyRetainsCloudPreference() {
        for profile in [trained(cloud: [0.5, 5, 1.5]), trained(local: [0.1, 0.1, 3])] {
            XCTAssertEqual(profile.choose(inputTokens: 1_000, localCapacity: 8_192, connection: wifi, now: now), .cloud)
        }
        XCTAssertEqual(trained().choose(inputTokens: 1_000, localCapacity: 8_192, connection: wifi, now: now), .onDevice)
    }

    /// Quality requirements override established local speed, offline state and cloud cooldown.
    func testCloudRequirementOverridesLearnedAndHealthPreferences() {
        var profile = trained()
        profile.recordFailure(connection: wifi, now: now)
        for connection in [wifi, .init(kind: .offline)] {
            XCTAssertEqual(profile.choose(inputTokens: 1_000, localCapacity: 8_192, connection: connection,
                now: now, policy: .cloudRequired), .cloud)
        }
    }

    /// Old caches decode as unspecified output and fresh sessions without being reused for richer metadata.
    func testLegacySamplesRemainReadable() throws {
        let data = try JSONEncoder().encode(trained())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var samples = try XCTUnwrap(json["samples"] as? [[String: Any]])
        for index in samples.indices { samples[index].removeValue(forKey: "workload") }
        json["samples"] = samples
        let profile = try JSONDecoder().decode(PerformanceProfile.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(profile.choose(inputTokens: 1_000, localCapacity: 8_192, connection: wifi, now: now), .onDevice)
        XCTAssertEqual(profile.choose(inputTokens: 1_000, localCapacity: 8_192, connection: wifi, now: now,
            workload: .init(expectedOutputTokens: 100)), .cloud)
    }

    /// Public orchestration persists only the supplied output budget and session flags alongside timings.
    @MainActor
    func testWorkloadMetadataPersists() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workload = RoutingWorkload(expectedOutputTokens: 600, localSession: .reused)
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        let _: Int? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            workload: workload, cloud: { 1 }, onDevice: { 2 })
        let restored = AdaptiveRouter(directory: directory, monitorConnection: false)
        XCTAssertEqual(restored.profile.samples.first?.workload, workload)
    }

    /// An expected output larger than the configured reserve still protects the full local context.
    @MainActor
    func testExpectedOutputAlsoReservesLocalCapacity() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false,
            configuration: .init(localResponseReserve: 100))
        let result: Int? = try await router.respond(inputTokens: 900, localContextCapacity: 1_000,
            workload: .init(expectedOutputTokens: 200), cloud: { nil },
            onDevice: { XCTFail("Generation must fit alongside the full input."); return 0 })
        XCTAssertNil(result)
    }
}
