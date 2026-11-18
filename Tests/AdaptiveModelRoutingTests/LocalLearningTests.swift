import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Protects quota when a fresh local probe is faster than stale weighted local history.
@MainActor
final class LocalLearningTests: XCTestCase {
    private let wifi = PerformanceProfile.Connection(kind: .wifi)

    /// Loads real cache-shaped timings with old slow local work and one newly fast local observation.
    private func fixture(configuration: RoutingConfiguration = .init(calibration: .paired(refreshEvery: 10))) throws -> (AdaptiveRouter, URL) {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date.now
        var profile = PerformanceProfile()
        for index in 0..<6 {
            for route in [InferenceRoute.onDevice, .cloud] {
                profile.record(model: route, tokens: 100, seconds: route == .onDevice ? 3.3 : 0.6,
                    connection: wifi, now: now.addingTimeInterval(Double(index - 12)))
            }
        }
        profile.record(model: .onDevice, tokens: 100, seconds: 0.3, connection: wifi,
            now: now.addingTimeInterval(-1))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "system": "local-learning",
            "profile": encoded, "lastCloudUse": now.addingTimeInterval(-5).timeIntervalSinceReferenceDate])
        try data.write(to: directory.appendingPathComponent("latency.json"))
        let router = AdaptiveRouter(directory: directory, system: "local-learning", monitorConnection: false,
            configuration: configuration)
        router.updateConnection(wifi)
        return (router, directory)
    }

    /// A newly fast local observation earns free foreground learning instead of waiting for more paid cloud calls.
    func testFreshFasterLocalObservationReturnsWithoutPaidRelearning() async throws {
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var cloudCalls = 0
        for _ in 0..<2 {
            let decision = router.decision(inputTokens: 100, localCapacity: 8_192)
            XCTAssertEqual(decision.route, .onDevice)
            XCTAssertEqual(decision.reason, .localCalibration)
            let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { cloudCalls += 1; return "cloud" }, onDevice: { "local" })
            XCTAssertEqual(result.route, .onDevice)
        }
        XCTAssertEqual(cloudCalls, 0)
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).reason, .localFaster)
    }

    /// Selection observers see persisted local consumption without changing the cloud-use cooldown.
    func testObserverSeesConsumptionWithoutCloudUse() async throws {
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("latency.json")
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let proof = router.profile.samples.last { $0.model == .onDevice }!.date.timeIntervalSinceReferenceDate
        var observed = false
        for _ in 0..<30 { XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).reason, .localCalibration) }
        _ = try await router.withRequest(deadline: nil, onAttempt: nil) { context in
            try await router.performDetailed(context: context, inputTokens: 100, localContextCapacity: 8_192,
                policy: .automatic, workload: .init(), availability: .init(), onDecision: { decision in
                    observed = true
                    XCTAssertEqual(decision.reason, .localCalibration)
                    XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).route, .cloud)
                    let data = try? Data(contentsOf: file)
                    let cache = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    XCTAssertGreaterThan(cache?["lastLocalLearning"] as? Double ?? 0, proof)
                    XCTAssertEqual(cache?["lastCloudUse"] as? Double, before["lastCloudUse"] as? Double)
                }, shouldFallback: { _, _ in false }, cloud: { _, _ in "cloud" }, onDevice: { _, _ in "local" })
        }
        XCTAssertTrue(observed)
    }

    /// Concurrent foreground requests cannot reuse a local observation before its worker succeeds.
    func testConcurrentRequestsCannotReuseLocalProof() async throws {
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let first = Task { @MainActor in
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { "cloud" }, onDevice: {
                    calls += 1
                    await withCheckedContinuation { release = $0 }
                    return "local"
                })
        }
        while release == nil { await Task.yield() }
        var others: [Task<RoutingResult<String>, any Error>] = []
        for _ in 0..<8 {
            others.append(Task { @MainActor in
                try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                    cloud: { "cloud" }, onDevice: { calls += 1; return "unexpected" })
            })
        }
        for other in others { let value = try await other.value; XCTAssertEqual(value.route, .cloud) }
        XCTAssertEqual(calls, 1)
        release?.resume()
        _ = try await first.value
    }

    /// Unsuccessful attempts cannot replay their old observation after an ordinary disk-backed relaunch.
    func testUnsuccessfulLearningStaysConsumedAfterRelaunch() async throws {
        for outcome in ["failed", "timeout", "cancelled"] {
            let (router, directory) = try fixture(configuration: outcome == "timeout"
                ? .init(requestDeadline: .after(.milliseconds(20))) : .fastest)
            defer { try? FileManager.default.removeItem(at: directory) }
            var localCalls = 0
            var cloudCalls = 0
            do {
                _ = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                    cloud: { cloudCalls += 1; return "cloud" }, onDevice: {
                        localCalls += 1
                        if outcome == "failed" { throw URLError(.badURL) }
                        if outcome == "cancelled" { throw CancellationError() }
                        try await Task.sleep(for: .milliseconds(100))
                        return "local"
                    })
                XCTFail("Unsuccessful learning must terminate.")
            } catch {}
            XCTAssertEqual(cloudCalls, 0, "Exploration cannot relax permanent-error, deadline or cancellation policy.")
            let restarted = AdaptiveRouter(directory: directory, system: "local-learning", monitorConnection: false,
                configuration: .init(calibration: .paired(refreshEvery: 10)))
            restarted.updateConnection(wifi)
            for _ in 0..<5 {
                let result = try await restarted.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                    cloud: { cloudCalls += 1; return "cloud" }, onDevice: { localCalls += 1; return "unexpected" })
                XCTAssertEqual(result.route, .cloud)
            }
            XCTAssertEqual(localCalls, 1)
            XCTAssertEqual(cloudCalls, 5)
        }
    }

    /// Cancelling the originating caller cannot restore a consumed local observation.
    func testCallerCancellationCannotRestoreLocalProof() async throws {
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let request = Task { @MainActor in
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { "cloud" }, onDevice: {
                    calls += 1
                    try await Task.sleep(for: .seconds(60))
                    return "local"
                })
        }
        while calls == 0 { await Task.yield() }
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled learning must throw.") }
        catch is CancellationError {}
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).route, .cloud)
        XCTAssertEqual(calls, 1)
    }

    /// Owned-stream failures consume permission while preserving permanent-error recovery policy.
    func testOwnedStreamFailureCannotRepeatLocalLearning() async throws {
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var localCalls = 0
        var cloudCalls = 0
        do {
            for try await _ in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { RoutingProviderStream { cloudCalls += 1; $0.yield("cloud") } },
                onDevice: { RoutingProviderStream<String> { _ in localCalls += 1; throw URLError(.badURL) } }) {}
            XCTFail("Permanent local failure must throw.")
        } catch let error as URLError { XCTAssertEqual(error.code, .badURL) }
        XCTAssertEqual(cloudCalls, 0)
        for _ in 0..<5 {
            for try await event in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { RoutingProviderStream { cloudCalls += 1; $0.yield("cloud") } },
                onDevice: { RoutingProviderStream { localCalls += 1; $0.yield("unexpected") } }) {
                if case .completed(let result) = event { XCTAssertEqual(result.route, .cloud) }
            }
        }
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(cloudCalls, 5)
    }

    /// Explicit presets, hard policies, readiness, capacity and quota pressure retain precedence.
    func testExplicitMarginsAndConstraintsRemainAuthoritative() throws {
        for configuration in [RoutingConfiguration.balanced, .qualityFirst, .latencyFirst, .init(calibration: .singleProvider)] {
            let (router, directory) = try fixture(configuration: configuration)
            defer { try? FileManager.default.removeItem(at: directory) }
            XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192).route, .cloud)
        }
        let (router, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192, policy: .cloudRequired).reason, .cloudRequired)
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192, policy: .localOnly).reason, .localOnly)
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 400).reason, .localContextExceeded)
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192,
            availability: .init(onDevice: false)).reason, .localUnavailable)
        XCTAssertEqual(router.decision(inputTokens: 100, localCapacity: 8_192,
            availability: .init(cloudQuota: .approachingLimit)).reason, .cloudQuotaConserved)
    }

    /// Reactive learning cannot overrule a newer cloud observation that is faster than the local candidate.
    func testLatestFasterCloudObservationPreventsUnnecessaryLocalExploration() {
        let now = Date.now
        for cloudSeconds in [0.2, 0.3, 0.4] {
            var profile = PerformanceProfile()
            for index in 0..<6 {
                for route in [InferenceRoute.onDevice, .cloud] {
                    profile.record(model: route, tokens: 100, seconds: route == .onDevice ? 3.3 : 0.6,
                        connection: wifi, now: now.addingTimeInterval(Double(index - 12)))
                }
            }
            profile.record(model: .onDevice, tokens: 100, seconds: 0.3, connection: wifi,
                now: now.addingTimeInterval(-1))
            profile.record(model: .cloud, tokens: 100, seconds: cloudSeconds, connection: wifi, now: now)
            let decision = profile.executionDecision(inputTokens: 100, localCapacity: 8_192,
                connection: wifi, now: now, configuration: .fastest, policy: .automatic, workload: .init(),
                availability: .init(), lastCloudUse: now, lastLocalLearning: .distantPast)
            XCTAssertEqual(decision.route, cloudSeconds > 0.3 ? .onDevice : .cloud)
        }
    }
}
