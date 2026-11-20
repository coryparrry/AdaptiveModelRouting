import Darwin
import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Measures choices against an independent eligible-provider latency oracle without making model requests.
final class RoutingAccuracyTests: XCTestCase {
    /// Captures actual simulated regret, cloud work and decision traces rather than only asserting estimator arithmetic.
    private struct Metrics: Codable {
        let name: String
        var cloudForeground = 0
        var cloudProbes = 0
        var localProbes = 0
        var decisionsAfterWarmup = 0
        var correctAfterWarmup = 0
        var regretSeconds = 0.0
        var routes: [InferenceRoute] = []
        var cloudSteps: [Int] = []
    }

    /// Replays sequential requests, recording actual completion order and preserving cloud pacing across path changes.
    private func simulate(name: String, steps: Int = 240,
        local: (Int) -> Double, cloud: (Int) -> Double,
        quota: (Int) -> CloudQuotaStatus = { _ in .available },
        path: (Int) -> PerformanceProfile.Connection.Kind = { _ in .wifi }
    ) -> Metrics {
        var profile = PerformanceProfile()
        var schedule = RoutingCalibrationSchedule()
        var metrics = Metrics(name: name)
        let config = RoutingConfiguration.fastest
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var previous: PerformanceProfile.Connection.Kind?
        for step in 0..<steps {
            let now = base.addingTimeInterval(Double(step) * 30)
            let connection = PerformanceProfile.Connection(kind: path(step))
            if let previous, previous != connection.kind {
                profile.changedConnection(connection)
                schedule.resetCadence()
            }
            previous = connection.kind
            let ready = RoutingAvailability(cloudQuota: quota(step)).restricted(to: .automatic, conserveQuota: true)
            let decision = profile.decision(inputTokens: 100, localCapacity: 8_192, connection: connection,
                now: now, availability: ready)
            let oracle: InferenceRoute = !ready.cloud || local(step) <= cloud(step) ? .onDevice : .cloud
            metrics.routes.append(decision.route)
            if step >= 3 {
                metrics.decisionsAfterWarmup += 1
                if decision.route == oracle { metrics.correctAfterWarmup += 1 }
                let actual = decision.route == .cloud ? cloud(step) : local(step)
                let best = oracle == .cloud ? cloud(step) : local(step)
                metrics.regretSeconds += max(0, actual - best)
            }
            let other: InferenceRoute = decision.route == .cloud ? .onDevice : .cloud
            let required = profile.needsCalibration(inputTokens: 100, localCapacity: 8_192,
                connection: connection, now: now, configuration: config, policy: .automatic,
                workload: .init(), availability: ready, decision: decision)
            var operations = [decision.route]
            if schedule.shouldProbe(required: required, configuration: config.calibration, route: other,
                cloudInterval: config.cloudRetryInterval, now: now) {
                operations.append(other)
                schedule.resetCadence()
                if other == .cloud { metrics.cloudProbes += 1 } else { metrics.localProbes += 1 }
            }
            if decision.route == .cloud { metrics.cloudForeground += 1 }
            if operations.contains(.cloud) {
                XCTAssertTrue(ready.cloud, "Quota-ineligible cloud operation at \(step), \(name)")
                metrics.cloudSteps.append(step)
                schedule.recordCloudUse(at: now)
            }
            let completed = operations.map { ($0, $0 == .cloud ? cloud(step) : local(step)) }.sorted { $0.1 < $1.1 }
            for (route, seconds) in completed {
                profile.record(model: route, tokens: 100, seconds: seconds, connection: connection,
                    now: now.addingTimeInterval(seconds))
            }
        }
        return metrics
    }

    /// Stationary workloads choose the eligible fastest provider after learning, without high-frequency PCC probes.
    func testStationaryAccuracyAndPCCEfficiency() throws {
        let local = simulate(name: "stationary-local", local: { _ in 0.25 }, cloud: { _ in 1 })
        let cloud = simulate(name: "stationary-cloud", local: { _ in 1 }, cloud: { _ in 0.25 })
        for result in [local, cloud] {
            XCTAssertEqual(result.correctAfterWarmup, result.decisionsAfterWarmup)
            XCTAssertEqual(result.regretSeconds, 0)
        }
        XCTAssertEqual(local.cloudForeground, 3)
        XCTAssertEqual(local.cloudProbes, 11, "Two simulated hours should not probe PCC every ten rapid requests.")
        XCTAssertEqual(cloud.cloudProbes, 0, "PCC foreground work must never cause an additional PCC operation.")
        try save([local, cloud], name: "stationary")
    }

    /// Separated latency distributions remain correctly ranked despite bounded deterministic jitter.
    func testSeparatedJitterDoesNotSpendMoreQuotaOrChangeTheWinner() throws {
        let result = simulate(name: "bounded-jitter", local: { 0.25 + Double(($0 * 17 + 3) % 11 - 5) / 1_000 },
            cloud: { 1 + Double(($0 * 7 + 2) % 11 - 5) / 300 })
        XCTAssertEqual(result.correctAfterWarmup, result.decisionsAfterWarmup)
        XCTAssertEqual(result.cloudForeground, 3)
        XCTAssertEqual(result.cloudProbes, 11)
        try save([result], name: "jitter")
    }

    /// Age decay lets the first new observation beat obsolete cloud timings rather than spending several probes.
    func testOnePCCProbeCanDetectAChangedLatencyRegime() {
        let now = Date.now
        var profile = PerformanceProfile()
        for index in 0..<3 {
            let date = now.addingTimeInterval(Double(index - 603))
            profile.record(model: .onDevice, tokens: 100, seconds: 1, connection: .init(kind: .wifi), now: date)
            profile.record(model: .cloud, tokens: 100, seconds: 4, connection: .init(kind: .wifi), now: date)
        }
        profile.record(model: .onDevice, tokens: 100, seconds: 1, connection: .init(kind: .wifi), now: now.addingTimeInterval(-1))
        profile.record(model: .cloud, tokens: 100, seconds: 0.2, connection: .init(kind: .wifi), now: now)
        let result = profile.decision(inputTokens: 100, localCapacity: 8_192, connection: .init(kind: .wifi), now: now)
        XCTAssertEqual(result.route, .cloud)
        XCTAssertLessThan(result.cloudEstimate!.seconds, result.localEstimate!.seconds)
    }

    /// Representative latency shifts recover within one cloud exploration interval or two foreground observations.
    func testAdaptationAccuracyAgainstChangingLatencyOracle() throws {
        let improves = simulate(name: "cloud-speedup", local: { _ in 0.4 }, cloud: { $0 < 63 ? 1 : 0.05 })
        let slows = simulate(name: "local-throttling", local: { $0 < 63 ? 0.25 : 4 }, cloud: { _ in 1 })
        let improvedAt = improves.routes.indices.first { $0 >= 63 && improves.routes[$0] == .cloud }!
        let throttledAt = slows.routes.indices.first { $0 >= 63 && slows.routes[$0] == .cloud }!
        XCTAssertLessThanOrEqual((improvedAt - 63) * 30, 660)
        XCTAssertLessThanOrEqual(throttledAt - 63, 2)
        XCTAssertTrue(improves.routes.suffix(100).allSatisfy { $0 == .cloud })
        XCTAssertTrue(slows.routes.suffix(100).allSatisfy { $0 == .cloud })
        try save([improves, slows], name: "adaptation")
    }

    /// Quota pressure overrides speed explicitly and permits recovery when the observed quota resets.
    func testQuotaChangesAndNetworkChangesAgainstEligibleOracle() throws {
        let quota = simulate(name: "shared-user-quota", local: { _ in 1 }, cloud: { _ in 0.2 },
            quota: { $0 < 60 || $0 >= 120 ? .available : ($0 < 90 ? .approachingLimit : .exhausted) })
        XCTAssertTrue(quota.cloudSteps.allSatisfy { $0 < 60 || $0 >= 120 })
        XCTAssertTrue(quota.routes[60..<120].allSatisfy { $0 == .onDevice })
        XCTAssertEqual(quota.routes[120], .cloud)
        let path = simulate(name: "network-change", local: { _ in 0.3 }, cloud: { $0 < 100 ? 0.5 : 2 },
            path: { $0 < 100 ? .wifi : .cellular })
        XCTAssertTrue(path.routes.suffix(100).allSatisfy { $0 == .onDevice })
        XCTAssertLessThanOrEqual(path.routes[100..<110].filter { $0 == .cloud }.count, 3)
        try save([quota, path], name: "quota-network")
    }

    /// Bounded selection preserves full stable-sort semantics for unordered caches and tied dates.
    func testBoundedSelectorMatchesStableSortWithShuffledDatesAndTies() throws {
        var source = PerformanceProfile()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<20 {
            let date = base.addingTimeInterval(Double(index / 4))
            source.record(model: .onDevice, tokens: 100, seconds: Double(index % 7 + 1) / 4,
                connection: .init(kind: .wifi), now: date)
            source.record(model: .cloud, tokens: 100, seconds: Double((19 - index) % 7 + 1) / 4,
                connection: .init(kind: .wifi), now: date)
        }
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        let rows = original["samples"] as! [[String: Any]]
        for seed in 0..<40 {
            let offset = (seed * 13 + 7) % rows.count
            var shuffled = Array(rows[offset...] + rows[..<offset])
            if seed % 2 == 1 { shuffled.reverse() }
            var cache = original
            cache["samples"] = shuffled
            let decoded = try JSONDecoder().decode(PerformanceProfile.self, from: JSONSerialization.data(withJSONObject: cache))
            for limit in [3, 6, 16, 17, 65, 128] {
                let decision = decoded.decision(inputTokens: 100, localCapacity: 8_192, connection: .init(kind: .wifi),
                    now: base.addingTimeInterval(10), configuration: .init(predictionSampleLimit: limit))
                for route in [InferenceRoute.onDevice, .cloud] {
                    let sorted = shuffled.filter { $0["model"] as? String == route.rawValue }
                        .sorted { ($0["date"] as! Double) > ($1["date"] as! Double) }.prefix(limit)
                    let newest = sorted.first!["date"] as! Double
                    var weighted = 0.0
                    var weights = 0.0
                    for (rank, sample) in sorted.enumerated() {
                        let weight = pow(0.5, Double(rank)) * pow(0.5, (newest - (sample["date"] as! Double)) / 300)
                        weighted += (sample["seconds"] as! Double) * weight
                        weights += weight
                    }
                    let actual = route == .cloud ? decision.cloudEstimate : decision.localEstimate
                    XCTAssertEqual(actual!.seconds, weighted / weights, accuracy: 1e-12,
                        "seed=\(seed),limit=\(limit),route=\(route)")
                    XCTAssertEqual(actual!.sampleCount, min(limit, 20))
                }
            }
        }
    }

    /// Caps CPU time for synchronous routing decisions over a full bounded history.
    func testBoundedHistoryDecisionBenchmark() throws {
        var profile = PerformanceProfile()
        let now = Date.now
        for index in 0..<128 {
            let date = now.addingTimeInterval(Double(index - 128))
            profile.record(model: .onDevice, tokens: 100, seconds: 0.3, connection: .init(kind: .wifi), now: date)
            profile.record(model: .cloud, tokens: 100, seconds: 0.6, connection: .init(kind: .wifi), now: date)
        }
        // Thread CPU time excludes time when a shared runner schedules other work.
        let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var local = 0
        for _ in 0..<10_000 {
            if profile.choose(inputTokens: 100, localCapacity: 8_192, connection: .init(kind: .wifi), now: now) == .onDevice { local += 1 }
        }
        let finished = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let cpuSeconds = (Double(finished) - Double(began)) / 1e9
        XCTAssertEqual(local, 10_000)
        XCTAssertGreaterThan(cpuSeconds, 0, "The benchmark must record CPU time.")
        XCTAssertLessThan(cpuSeconds, 5, "Bounded-history routing should not require model-scale CPU time.")
        print("Routing benchmark: 10000 decisions, \(cpuSeconds) CPU seconds, \(cpuSeconds * 100) CPU microseconds/decision")
    }

    /// Saves deterministic scenario traces for accuracy/regret and quota inspection without logging prompts.
    private func save(_ metrics: [Metrics], name: String) throws {
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/quota-accuracy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metrics).write(to: root.appendingPathComponent("\(configuration)-\(name).json"))
    }
}
