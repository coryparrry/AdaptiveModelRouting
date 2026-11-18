import XCTest
import Foundation
import AdaptiveModelRouting

/// Replays device and connection conditions without making duplicate or live model requests.
final class AdaptiveRouterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let wifi = PerformanceProfile.Connection(kind: .wifi)
    private let cellular = PerformanceProfile.Connection(kind: .cellular, expensive: true)

    /// Produces three recent observations for a comparable request size.
    private func profile(local: Double, cloud: Double) -> PerformanceProfile {
        var profile = PerformanceProfile()
        for index in 0..<3 {
            let date = now.addingTimeInterval(Double(index - 3))
            profile.record(model: .onDevice, tokens: 2_000, seconds: local, connection: wifi, now: date)
            profile.record(model: .cloud, tokens: 2_000, seconds: cloud, connection: wifi, now: date)
        }
        return profile
    }

    /// Prefers the stronger reasoning lane before there is enough comparable timing evidence.
    func testColdStartPrefersPCCAtEverySize() {
        let profile = PerformanceProfile()
        for tokens in [100, 2_000, 7_000, 12_000] {
            XCTAssertEqual(profile.choose(inputTokens: tokens, localCapacity: 8_192, connection: wifi, now: now), .cloud)
        }
    }

    /// Learns a fast phone from an empty profile without relying on cloud errors or seeded timings.
    func testBootstrapsLocalTimingOnAHealthyConnection() {
        var profile = PerformanceProfile()
        var routes: [InferenceRoute] = []
        for index in 0..<12 {
            let date = now.addingTimeInterval(Double(index))
            let route = profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi, now: date, configuration: .init(calibration: .singleProvider))
            routes.append(route)
            profile.record(model: route, tokens: 2_000, seconds: route == .onDevice ? 0.5 : 2,
                connection: wifi, now: date, configuration: .init(calibration: .singleProvider))
        }
        XCTAssertEqual(routes, Array(repeating: [.cloud, .cloud, .cloud, .onDevice], count: 3).flatMap { $0 })
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(12), configuration: .init(calibration: .singleProvider)), .onDevice)
    }

    /// Finishes bounded calibration with PCC preferred when it has the better measured performance.
    func testBootstrapKeepsPCCWhenItWinsAndRetriesFailedLocalCalibration() {
        var profile = PerformanceProfile()
        for index in 0..<12 {
            let date = now.addingTimeInterval(Double(index))
            let route = profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi, now: date, configuration: .init(calibration: .singleProvider))
            profile.record(model: route, tokens: 2_000, seconds: route == .onDevice ? 3 : 1,
                connection: wifi, now: date, configuration: .init(calibration: .singleProvider))
        }
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(12), configuration: .init(calibration: .singleProvider)), .cloud)
        profile.recordFailure(model: .onDevice, connection: wifi, now: now.addingTimeInterval(12), configuration: .init(calibration: .singleProvider))
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: cellular,
            now: now.addingTimeInterval(13), configuration: .init(calibration: .singleProvider)), .cloud)
    }

    /// A fast phone can choose local while a slower phone with the same connection chooses PCC.
    func testLearnsDeviceSpeedWithoutATokenThreshold() {
        let fast = profile(local: 0.5, cloud: 1.5)
        let slow = profile(local: 3, cloud: 1.5)
        XCTAssertEqual(fast.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi, now: now), .onDevice)
        XCTAssertEqual(slow.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi, now: now), .cloud)
        XCTAssertEqual(fast.choose(inputTokens: 9_000, localCapacity: 8_192, connection: wifi, now: now), .cloud)
    }

    /// A small latency saving does not displace the preferred reasoning model.
    func testQualityPreferenceAndSparseSamplesKeepPCC() {
        XCTAssertEqual(profile(local: 1.3, cloud: 1.5).choose(
            inputTokens: 2_000, localCapacity: 8_192, connection: wifi, now: now, configuration: .balanced), .cloud)
        var sparse = PerformanceProfile()
        sparse.record(model: .onDevice, tokens: 2_000, seconds: 0.1, connection: wifi, now: now)
        sparse.record(model: .cloud, tokens: 2_000, seconds: 5, connection: wifi, now: now)
        XCTAssertEqual(sparse.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi, now: now), .cloud)
    }

    /// New cloud paths retain qualified local evidence while rebuilding cloud estimates through probes.
    func testSeparatesConnectionProfilesAndResetsOnPathChange() {
        var profile = profile(local: 1, cloud: 4)
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi, now: now), .onDevice)
        for path in [cellular, .init(kind: .wifi, constrained: true)] {
            let result = profile.decision(inputTokens: 2_000, localCapacity: 8_192, connection: path, now: now)
            XCTAssertEqual(result.route, .onDevice)
            XCTAssertEqual(result.reason, .insufficientEvidence)
            XCTAssertNotNil(result.localEstimate)
            XCTAssertNil(result.cloudEstimate)
        }
        profile.changedConnection(wifi)
        XCTAssertEqual(profile.samples.filter { $0.model == .onDevice }.count, 3)
        let result = profile.decision(inputTokens: 2_000, localCapacity: 8_192, connection: wifi, now: now)
        XCTAssertEqual(result.route, .onDevice)
        XCTAssertNil(result.cloudEstimate)
    }

    /// Offline and failed connections select local, with a bounded cloud retry cooldown.
    func testOfflineAndFailureBackoffRecoverAutomatically() {
        var profile = PerformanceProfile()
        XCTAssertEqual(profile.choose(inputTokens: 12_000, localCapacity: 8_192,
            connection: .init(kind: .offline), now: now), .onDevice)
        profile.recordFailure(connection: wifi, now: now)
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(59)), .onDevice)
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(61)), .cloud)
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: cellular, now: now), .cloud)
    }

    /// Periodically retries PCC so an old slow connection does not permanently select local.
    func testRetriesPCCAndRejectsStaleOrDissimilarHistory() {
        let profile = profile(local: 1, cloud: 4)
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(601), configuration: .init(calibration: .singleProvider)), .cloud)
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(8 * 86_400), configuration: .init(calibration: .singleProvider)), .cloud)
        XCTAssertEqual(profile.choose(inputTokens: 500, localCapacity: 8_192, connection: wifi, now: now, configuration: .init(calibration: .singleProvider)), .cloud)
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(-100), configuration: .init(calibration: .singleProvider)), .cloud)
    }

    /// Recent observations outweigh old connection slowness and invalid timings are ignored.
    func testAdaptsToRecoveryAndBoundsMetadata() {
        var profile = profile(local: 1, cloud: 4)
        for index in 0..<3 {
            profile.record(model: .cloud, tokens: 2_000, seconds: 0.5, connection: wifi,
                now: now.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(profile.choose(inputTokens: 2_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(3)), .cloud)
        let before = profile.samples.count
        for seconds in [0, -1, Double.infinity, Double.nan] {
            profile.record(model: .cloud, tokens: 2_000, seconds: seconds, connection: wifi, now: now)
        }
        XCTAssertEqual(profile.samples.count, before)
        for index in 0..<200 {
            profile.record(model: .cloud, tokens: 2_000, seconds: 1, connection: wifi,
                now: now.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(profile.samples.filter { $0.model == .cloud }.count, 128)
        XCTAssertEqual(profile.samples.filter { $0.model == .onDevice }.count, 3)
        XCTAssertLessThanOrEqual(profile.samples.count, 256)
    }

    /// Stores only timing metadata and reloads it locally, resetting calibration on an OS update.
    @MainActor
    func testLocalPersistenceExcludesModelContentAndOSUpdatesResetIt() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = singleProviderRouter(directory: directory, system: "test-os", monitorConnection: false)
        router.updateConnection(wifi)
        let value = try await router.measure(model: .cloud, inputTokens: 2_000, snapshot: router.snapshot()) {
            "Private meeting words must not be stored in performance metadata."
        }
        XCTAssertTrue(value.hasPrefix("Private"))
        let data = try Data(contentsOf: directory.appendingPathComponent("latency.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private meeting"))
        XCTAssertEqual(singleProviderRouter(directory: directory, system: "test-os", monitorConnection: false)
            .profile.samples.count, 1)
        XCTAssertEqual(singleProviderRouter(directory: directory, system: "new-os", monitorConnection: false)
            .profile.samples.count, 0)
        XCTAssertTrue(try hasBackupExclusion(at: directory.appendingPathComponent("latency.json")))
    }

    /// Unavailable or failed requests cause backoff without making additional inference calls.
    @MainActor
    func testMeasuresSelectedRequestAndLearnsCloudFailure() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = singleProviderRouter(directory: directory, monitorConnection: false)
        router.updateConnection(wifi)
        var calls = 0
        let _: Int? = try await router.measure(model: .cloud, inputTokens: 2_000, snapshot: router.snapshot(),
            available: { $0 != nil }) {
                calls += 1
                return nil
            }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(router.choose(inputTokens: 2_000, localCapacity: 8_192), .onDevice)
        XCTAssertTrue(router.profile.samples.isEmpty)
        do {
            let _: Int = try await router.measure(model: .cloud, inputTokens: 2_000, snapshot: router.snapshot()) {
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Provider errors must remain visible to the normal local fallback.")
        } catch is URLError {}
        XCTAssertEqual(router.profile.failures.count, 1)
    }

    /// A response from a prior path generation must not calibrate the newly observed network.
    @MainActor
    func testIgnoresInFlightResponseAfterConnectionChange() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = singleProviderRouter(directory: directory, monitorConnection: false)
        router.updateConnection(wifi)
        let old = router.snapshot()
        let value = try await router.measure(model: .cloud, inputTokens: 2_000, snapshot: old) {
            router.updateConnection(self.cellular)
            return 1
        }
        XCTAssertEqual(value, 1)
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertTrue(router.profile.failures.isEmpty)
    }

    /// Early cancellation remains visible without changing latency estimates or cloud health.
    @MainActor
    func testCancellationDoesNotTrainTheRouter() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = singleProviderRouter(directory: directory, monitorConnection: false)
        for explicit in [true, false] {
            let operation = Task {
                try await router.measure(model: .cloud, inputTokens: 2_000, snapshot: router.snapshot()) {
                    if explicit { throw CancellationError() }
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 1
                }
            }
            do {
                _ = try await operation.value
                XCTFail("Cancelled inference must not become a successful timing sample.")
            } catch is CancellationError {}
        }
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertTrue(router.profile.failures.isEmpty)
    }

    /// Stalled cloud inference records backoff before caller cancellation without training latency.
    @MainActor
    func testSlowCloudCancellationBacksOffWithoutTrainingLatency() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = singleProviderRouter(directory: directory, monitorConnection: false,
            configuration: .init(slowCloudAfter: .milliseconds(5)))
        do {
            let _: Int = try await router.measure(model: .cloud, inputTokens: 2_000, snapshot: router.snapshot()) {
                let cutoff = ContinuousClock.now.advanced(by: .seconds(2))
                while router.profile.failures.isEmpty && ContinuousClock.now < cutoff {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(router.choose(inputTokens: 2_000, localCapacity: 8_192), .onDevice)
                throw CancellationError()
            }
            XCTFail("The caller must still receive cancellation.")
        } catch is CancellationError {}
        XCTAssertEqual(router.profile.failures.count, 1)
        XCTAssertTrue(router.profile.samples.isEmpty)
    }

    /// Late path callbacks cannot replace the newer connection or its request generation.
    @MainActor
    func testIgnoresReorderedPathCallbacks() {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = singleProviderRouter(directory: directory, monitorConnection: false)
        let older = ContinuousClock.now
        let newer = older.advanced(by: .seconds(1))
        router.updateConnection(cellular, observedAt: newer)
        let current = router.snapshot()
        router.updateConnection(wifi, observedAt: older)
        XCTAssertEqual(router.snapshot().connection, cellular)
        XCTAssertEqual(router.snapshot().generation, current.generation)
    }

    /// An unreadable performance cache is preserved instead of being overwritten during recording.
    @MainActor
    func testPreservesUnreadableCache() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("latency.json")
        let original = Data("unreadable existing cache".utf8)
        try original.write(to: file)
        let router = singleProviderRouter(directory: directory, monitorConnection: false)
        _ = try await router.measure(model: .onDevice, inputTokens: 2_000, snapshot: router.snapshot()) { 1 }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    /// A failed local calibration retries the cloud once without executing local inference twice.
    @MainActor
    func testLocalFailureRetriesPCCOnce() async throws {
        var local = 0
        var cloud = 0
        let result: String? = try await InferenceExecutor.respond(preferred: .onDevice, canUseLocalWhole: true,
            cloud: {
                cloud += 1
                return "cloud-result"
            }, onDevice: {
                local += 1
                throw URLError(.cannotLoadFromNetwork)
            })
        XCTAssertEqual(local, 1)
        XCTAssertEqual(cloud, 1)
        XCTAssertEqual(result, "cloud-result")
    }

    /// Offline oversized recordings request section fallback instead of overflowing either full local context.
    @MainActor
    func testOversizedLocalSelectionSkipsWholeRequests() async throws {
        let result: String? = try await InferenceExecutor.respond(preferred: .onDevice, canUseLocalWhole: false,
            cloud: { XCTFail("Offline selection must not try cloud inference."); return nil },
            onDevice: { XCTFail("Oversized local input must be split into sections."); throw CancellationError() })
        XCTAssertNil(result)
    }

    /// Cancelling a selected local calibration must not start another cloud request.
    @MainActor
    func testLocalCancellationDoesNotRetryCloud() async throws {
        do {
            let _: String? = try await InferenceExecutor.respond(preferred: .onDevice, canUseLocalWhole: true,
                cloud: { XCTFail("Cancelled requests must not change models."); return nil },
                onDevice: { throw CancellationError() })
            XCTFail("Cancellation must reach the caller.")
        } catch is CancellationError {}
    }
}
