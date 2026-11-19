import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Checks one-success-per-attempt cloud learning without real model or quota consumption.
@MainActor
final class CloudLearningTests: XCTestCase {
    private let wifi = PerformanceProfile.Connection(kind: .wifi)

    /// Loads qualified local timings and one configurable current cloud observation through the cache format.
    private func fixture(configuration: RoutingConfiguration = .fastest,
        latestLocalSeconds: TimeInterval? = nil, latestCloudSeconds: TimeInterval = 1,
        olderLocalSeconds: TimeInterval = 4
    ) throws -> (AdaptiveRouter, URL) {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date.now
        var profile = PerformanceProfile()
        for index in 0..<3 {
            profile.record(model: .onDevice, tokens: 100, seconds: olderLocalSeconds, connection: wifi,
                now: now.addingTimeInterval(Double(index - 6)))
        }
        profile.record(model: .cloud, tokens: 100, seconds: latestCloudSeconds,
            connection: wifi, now: now.addingTimeInterval(-1))
        if let latestLocalSeconds {
            profile.record(model: .onDevice, tokens: 100, seconds: latestLocalSeconds,
                connection: wifi, now: now.addingTimeInterval(-0.5))
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        let cache: [String: Any] = ["version": 1, "system": "cloud-learning", "profile": encoded,
            "lastCloudUse": now.addingTimeInterval(-2).timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: cache).write(to: directory.appendingPathComponent("latency.json"))
        let router = AdaptiveRouter(directory: directory, system: "cloud-learning", monitorConnection: false,
            configuration: configuration)
        router.updateConnection(wifi)
        return (router, directory)
    }

    /// Paid partial-cloud learning must beat both the weighted and latest comparable local observations.
    func testPartialCloudLearningRequiresBeatingLatestLocalObservation() async throws {
        for (local, cloud, older, expectedCloud) in [(0.3, 0.2, 4.0, true), (0.3, 0.3, 4.0, false),
            (0.3, 1.0, 4.0, false), (4.0, 3.0, 0.1, false)] {
            let (router, directory) = try fixture(latestLocalSeconds: local,
                latestCloudSeconds: cloud, olderLocalSeconds: older)
            defer { try? FileManager.default.removeItem(at: directory) }
            let decision = router.decision(inputTokens: 100, localCapacity: 8_192)
            XCTAssertEqual(decision.reason, .insufficientEvidence)
            XCTAssertNil(decision.cloudEstimate)
            if older == 4 { XCTAssertGreaterThan(decision.localEstimate?.seconds ?? 0, cloud) }
            else { XCTAssertLessThan(decision.localEstimate?.seconds ?? .infinity, cloud) }
            XCTAssertEqual(decision.route, expectedCloud ? .cloud : .onDevice)
            if !expectedCloud {
                var cloudCalls = 0
                for _ in 0..<20 {
                    let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                        cloud: { cloudCalls += 1; return "paid" }, onDevice: { "local" })
                    XCTAssertEqual(result.route, .onDevice)
                }
                await router.waitForCalibration()
                XCTAssertEqual(cloudCalls, 0)
            }
        }
    }

    /// Successful foreground observations complete calibration with two paid answers instead of two extra hidden probes.
    func testSuccessfulLearningReturnsToCloudWithoutWaitingForThreeProbeIntervals() async throws {
        let (router, directory) = try fixture(configuration: .init(calibration: .paired(refreshEvery: 10)))
        defer { try? FileManager.default.removeItem(at: directory) }
        for expectedCount in [2, 3] {
            let decision = router.decision(inputTokens: 100, localCapacity: 8_192)
            XCTAssertEqual(decision.route, .cloud)
            XCTAssertEqual(decision.reason, .insufficientEvidence)
            XCTAssertNotNil(decision.localEstimate)
            XCTAssertNil(decision.cloudEstimate)
            let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { "cloud" }, onDevice: { XCTFail("No local foreground or probe is required."); return "local" })
            XCTAssertEqual(result.value, "cloud")
            XCTAssertEqual(result.attempts.count, 1)
            XCTAssertEqual(router.profile.samples.filter { $0.model == .cloud }.count, expectedCount)
        }
        let learned = router.decision(inputTokens: 100, localCapacity: 8_192)
        XCTAssertEqual(learned.route, .cloud)
        XCTAssertEqual(learned.reason, .cloudPreferred)
        XCTAssertNotNil(learned.cloudEstimate)
    }

    /// Concurrent requests and previews cannot spend the same successful observation more than once.
    func testProofIsConsumedBeforeConcurrentDispatch() async throws {
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<30 {
            XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).route, .cloud)
        }
        var release: CheckedContinuation<Void, Never>?
        var cloudCalls = 0
        let first = Task { @MainActor in
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192, cloud: {
                cloudCalls += 1
                await withCheckedContinuation { release = $0 }
                return "cloud"
            }, onDevice: { "local" })
        }
        while release == nil { await Task.yield() }
        var others: [Task<RoutingResult<String>, any Error>] = []
        for _ in 0..<30 {
            others.append(Task { @MainActor in
                try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                    cloud: { cloudCalls += 1; return "unexpected" }, onDevice: { "local" })
            })
        }
        for other in others {
            let result = try await other.value
            XCTAssertEqual(result.route, .onDevice)
        }
        XCTAssertEqual(cloudCalls, 1)
        release?.resume()
        _ = try await first.value
        XCTAssertEqual(router.profile.samples.filter { $0.model == .cloud }.count, 2)
    }

    /// Reentrant selection observers see persisted consumption before any provider callback can begin.
    func testSelectionObserverSeesStrictlyPersistedReservation() async throws {
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proof = router.profile.samples.last { $0.model == .cloud }!.date.timeIntervalSinceReferenceDate
        var observed = false
        _ = try await router.withRequest(deadline: nil, onAttempt: nil) { context in
            try await router.performDetailed(context: context, inputTokens: 100, localContextCapacity: 8_192,
                policy: .automatic, workload: .init(), availability: .init(), onDecision: { decision in
                    observed = true
                    XCTAssertEqual(decision.route, .cloud)
                    XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).route, .onDevice)
                    let data = try? Data(contentsOf: directory.appendingPathComponent("latency.json"))
                    let cache = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    XCTAssertGreaterThan(cache?["lastCloudUse"] as? Double ?? 0, proof)
                }, shouldFallback: { _, _ in false }, cloud: { _, _ in "cloud" }, onDevice: { _, _ in "local" })
        }
        XCTAssertTrue(observed)
    }

    /// Cancelling the originating caller cannot restore its faster observation for repeated paid attempts.
    func testCallerCancellationCannotReuseProof() async throws {
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let request = Task { @MainActor in
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192, cloud: {
                calls += 1
                try await Task.sleep(for: .seconds(60))
                return "cloud"
            }, onDevice: { "local" })
        }
        while calls == 0 { await Task.yield() }
        request.cancel()
        do { _ = try await request.value; XCTFail("Caller cancellation must throw.") }
        catch is CancellationError {}
        for _ in 0..<20 {
            let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { calls += 1; return "unexpected" }, onDevice: { "local" })
            XCTAssertEqual(result.route, .onDevice)
        }
        XCTAssertEqual(calls, 1)
    }

    /// A failed owned stream cannot train or repeatedly spend the observation that selected it.
    func testOwnedStreamFailureCannotRepeatCloudLearning() async throws {
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        do {
            for try await _ in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { RoutingProviderStream<String> { _ in calls += 1; throw URLError(.badURL) } },
                onDevice: { RoutingProviderStream { $0.yield("local") } }) {}
            XCTFail("A permanent cloud stream failure must throw.")
        } catch let error as URLError { XCTAssertEqual(error.code, .badURL) }
        for _ in 0..<20 {
            for try await event in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { RoutingProviderStream { calls += 1; $0.yield("unexpected") } },
                onDevice: { RoutingProviderStream { $0.yield("local") } }) {
                if case .completed(let result) = event { XCTAssertEqual(result.route, .onDevice) }
            }
        }
        XCTAssertEqual(calls, 1)
    }

    /// Failed, unavailable and deadline-aborted attempts preserve their consumed proof across ordinary relaunches.
    func testUnsuccessfulLearningCannotRepeatAfterRelaunch() async throws {
        for outcome in ["failed", "unavailable", "timeout"] {
            let (router, directory) = try fixture(configuration: outcome == "timeout"
                ? .init(requestDeadline: .after(.milliseconds(20))) : .fastest)
            defer { try? FileManager.default.removeItem(at: directory) }
            var cloudCalls = 0
            do {
                _ = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192, cloud: {
                    cloudCalls += 1
                    if outcome == "failed" { throw URLError(.badURL) }
                    if outcome == "timeout" { try await Task.sleep(for: .milliseconds(100)) }
                    return nil as String?
                }, onDevice: { "local" })
                XCTAssertEqual(outcome, "unavailable")
            } catch {
                XCTAssertNotEqual(outcome, "unavailable")
            }
            let restarted = AdaptiveRouter(directory: directory, system: "cloud-learning", monitorConnection: false)
            restarted.updateConnection(wifi)
            for _ in 0..<20 {
                let result = try await restarted.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                    cloud: { cloudCalls += 1; return "unexpected" }, onDevice: { "local" })
                XCTAssertEqual(result.route, .onDevice)
            }
            XCTAssertEqual(cloudCalls, 1, outcome)
            XCTAssertEqual(restarted.profile.samples.filter { $0.model == .cloud }.count, 1)
        }
    }

    /// Network invalidation removes authorization, and clock rollback cannot restore a consumed observation.
    func testNetworkResetAndClockRollbackCannotRestoreProof() throws {
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).route, .cloud)
        router.updateConnection(wifi)
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).route, .onDevice)
        let now = Date.now
        var schedule = RoutingCalibrationSchedule()
        schedule.recordCloudUse(at: now)
        schedule.recordCloudUse(at: now.addingTimeInterval(-100))
        XCTAssertEqual(schedule.lastCloudUse, now)
        XCTAssertFalse(schedule.shouldProbe(required: true, configuration: .paired(), route: .cloud,
            cloudInterval: 600, now: now.addingTimeInterval(599)))
    }
}
