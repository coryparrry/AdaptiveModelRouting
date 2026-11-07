import Foundation
import XCTest
import AdaptiveModelRouting

/// Covers preset behavior, override propagation and explanations through the public core API.
final class PresetsAndDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let wifi = PerformanceProfile.Connection(kind: .wifi)

    /// Supplies stable, comparable measurements for policy comparisons.
    private func trained(local: Double, cloud: Double) -> PerformanceProfile {
        var profile = PerformanceProfile()
        for index in 0..<3 {
            let date = now.addingTimeInterval(Double(index - 3))
            profile.record(model: .cloud, tokens: 1_000, seconds: cloud, connection: wifi, now: date)
            profile.record(model: .onDevice, tokens: 1_000, seconds: local, connection: wifi, now: date)
        }
        return profile
    }

    /// The presets change actual policy decisions while explicit quality requirements remain binding.
    func testPresetsHaveDistinctBehavior() {
        let profile = trained(local: 1, cloud: 1.2)
        XCTAssertEqual(profile.decision(inputTokens: 1_000, localCapacity: 8_192, connection: wifi,
            now: now, configuration: .balanced).reason, .cloudPreferred)
        XCTAssertEqual(profile.decision(inputTokens: 1_000, localCapacity: 8_192, connection: wifi,
            now: now, configuration: .latencyFirst).reason, .localFaster)
        XCTAssertEqual(profile.decision(inputTokens: 1_000, localCapacity: 8_192, connection: wifi,
            now: now, configuration: .qualityFirst).reason, .insufficientEvidence)
        XCTAssertEqual(profile.decision(inputTokens: 1_000, localCapacity: 8_192, connection: wifi,
            now: now, configuration: .latencyFirst, policy: .cloudRequired).reason, .cloudRequired)
    }

    /// Overrides preserve unspecified preset fields and affect cooldown retention, not only selection.
    func testPresetOverridesAndCooldownRetention() {
        let configuration = RoutingConfiguration(customizing: .qualityFirst, failureBackoff: 120)
        XCTAssertEqual(configuration.minimumSamples, 5)
        XCTAssertEqual(configuration.variabilityAllowance, 1.5)
        XCTAssertEqual(configuration.failureBackoff, 120)
        var profile = PerformanceProfile()
        profile.recordFailure(connection: wifi, now: now, configuration: configuration)
        profile.record(model: .onDevice, tokens: 1_000, seconds: 1, connection: wifi,
            now: now.addingTimeInterval(70), configuration: configuration)
        XCTAssertEqual(profile.decision(inputTokens: 1_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(90), configuration: configuration).reason, .cloudBackoff)
        XCTAssertEqual(profile.decision(inputTokens: 1_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(121), configuration: configuration).reason, .insufficientEvidence)
    }

    /// Configurable sample lifetime and size tolerance apply consistently to storage and comparison.
    func testSampleRetentionAndMatchingOverrides() {
        let configuration = RoutingConfiguration(minimumSamples: 1, sizeTolerance: 0.5,
            cloudRetryInterval: 20 * 86_400, localRefreshInterval: 20 * 86_400, sampleLifetime: 14 * 86_400)
        var profile = PerformanceProfile()
        profile.record(model: .cloud, tokens: 1_000, seconds: 4, connection: wifi, now: now, configuration: configuration)
        profile.record(model: .onDevice, tokens: 1_000, seconds: 1, connection: wifi,
            now: now.addingTimeInterval(8 * 86_400), configuration: configuration)
        XCTAssertEqual(profile.samples.count, 2)
        let decision = profile.decision(inputTokens: 700, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(8 * 86_400), configuration: configuration)
        XCTAssertEqual(decision.reason, .localFaster)
        XCTAssertEqual(decision.localEstimate?.sampleCount, 1)
        XCTAssertEqual(decision.cloudEstimate?.seconds, 4)
    }

    /// Large valid sample requirements complete cold-start calibration without cross-provider eviction.
    func testLargeSampleMinimumCanLearnFromColdStart() {
        let minimum = 65
        let configuration = RoutingConfiguration(minimumSamples: minimum, predictionSampleLimit: minimum)
        var profile = PerformanceProfile()
        let requests = minimum * (minimum + 1)
        for index in 0..<requests {
            let date = now.addingTimeInterval(Double(index))
            let route = profile.choose(inputTokens: 1_000, localCapacity: 8_192, connection: wifi,
                now: date, configuration: configuration)
            profile.record(model: route, tokens: 1_000, seconds: route == .cloud ? 10 : 1,
                connection: wifi, now: date, configuration: configuration)
        }
        let decision = profile.decision(inputTokens: 1_000, localCapacity: 8_192, connection: wifi,
            now: now.addingTimeInterval(Double(requests)), configuration: configuration)
        XCTAssertEqual(decision.reason, .localFaster)
        XCTAssertEqual(decision.localEstimate?.sampleCount, minimum)
        XCTAssertEqual(decision.cloudEstimate?.sampleCount, minimum)
        for index in 0..<150 {
            profile.record(model: .onDevice, tokens: 1_000, seconds: 1, connection: wifi,
                now: now.addingTimeInterval(Double(requests + index)), configuration: configuration)
        }
        XCTAssertEqual(profile.samples.filter { $0.model == .onDevice }.count, 128)
        XCTAssertEqual(profile.samples.filter { $0.model == .cloud }.count, 128)
        XCTAssertEqual(profile.samples.count, 256)
    }

    /// Explanations report the original preference and successful fallback as distinct providers.
    @MainActor
    func testDetailedFallbackResult() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        var events: [RoutingAttempt] = []
        let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            onAttempt: { events.append($0) }, cloud: { nil }, onDevice: { "local" })
        XCTAssertEqual(result.value, "local")
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.decision.route, .cloud)
        XCTAssertEqual(result.decision.reason, .insufficientEvidence)
        XCTAssertEqual(result.route, .onDevice)
        XCTAssertTrue(result.didFallback)
        XCTAssertEqual(result.attempts.map(\.outcome), [.unavailable, .succeeded])
        XCTAssertEqual(events, result.attempts)
        XCTAssertTrue(events.allSatisfy { $0.seconds >= 0 })
    }

    /// Empty results distinguish oversized local recovery from provider unavailability without pretending success.
    @MainActor
    func testDetailedNoResultStatuses() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        let chunked: RoutingResult<String> = try await router.respondDetailed(inputTokens: 8_192,
            localContextCapacity: 8_192, cloud: { nil }, onDevice: { XCTFail("Input must be split."); return "invalid" })
        XCTAssertEqual(chunked.status, .requiresChunking)
        XCTAssertNil(chunked.route)
        let unavailable: RoutingResult<String> = try await router.respondDetailed(inputTokens: 10,
            localContextCapacity: 8_192, availability: .init(onDevice: false, cloud: false),
            cloud: { XCTFail("Unavailable cloud must not run."); return nil },
            onDevice: { XCTFail("Unavailable local must not run."); return "invalid" })
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertTrue(unavailable.attempts.isEmpty)
    }

    /// Known local unavailability cannot strand a usable cloud provider behind its old cooldown.
    @MainActor
    func testCloudRemainsUsableWhenLocalUnavailable() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        let _: String? = try await router.respond(inputTokens: 10, localContextCapacity: 8_192,
            cloud: { nil }, onDevice: { "local" })
        let result = try await router.respondDetailed(inputTokens: 10, localContextCapacity: 8_192,
            availability: .init(onDevice: false), cloud: { "cloud" },
            onDevice: { XCTFail("Unavailable local must not run."); return "invalid" })
        XCTAssertEqual(result.value, "cloud")
        XCTAssertEqual(result.decision.reason, .localUnavailable)
    }

    /// Failed and cancelled requests expose metadata while retaining their original thrown errors.
    @MainActor
    func testAttemptEventsSurviveThrownErrors() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        for cancelled in [false, true] {
            var events: [RoutingAttempt] = []
            do {
                let _: RoutingResult<String> = try await router.respondDetailed(inputTokens: 10, localContextCapacity: 8_192,
                    onAttempt: { events.append($0) }, cloud: {
                        if cancelled { throw CancellationError() }
                        throw URLError(.badURL)
                    }, onDevice: { XCTFail("Permanent errors must not switch models."); return "invalid" })
                XCTFail("The original error must propagate.")
            } catch is CancellationError { XCTAssertTrue(cancelled) }
            catch let error as URLError { XCTAssertEqual(error.code, .badURL) }
            XCTAssertEqual(events.map(\.outcome), [cancelled ? .cancelled : .failed])
        }
    }
}
