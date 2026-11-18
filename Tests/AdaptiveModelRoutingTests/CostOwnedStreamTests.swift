import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Tests the custom-provider ownership API at cancellation, deadline and partial-output boundaries.
@MainActor
final class CostOwnedStreamTests: XCTestCase {
    /// A timed-out secondary stream cannot reopen the generation slot while its producer ignores cancellation.
    func testOwnedStreamTimeoutKeepsSecondaryGenerationBounded() async throws {
        let router = AdaptiveRouter(monitorConnection: false,
            configuration: .init(calibration: .paired(timeout: .milliseconds(30))), persistence: .memoryOnly)
        let local = ControlledRoutingProvider()
        var localCalls = 0
        defer { local.release(); router.cancelCalibration() }
        for try await _ in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { RoutingProviderStream { $0.yield("cloud") } }, onDevice: {
                RoutingProviderStream { continuation in
                    localCalls += 1
                    let value = await local.call()
                    try Task.checkCancellation()
                    continuation.yield(value)
                }
            }) {}
        await local.started.wait()
        await router.waitForCalibration()
        XCTAssertTrue(router.isCalibrating)
        for _ in 0..<4 {
            for try await _ in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { RoutingProviderStream { $0.yield("cloud") } },
                onDevice: { RoutingProviderStream { localCalls += 1; $0.yield("unexpected extra local") } }) {}
        }
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(router.lastCalibrationAttempt?.outcome, .timedOut)
        local.release()
        await local.finished.wait()
    }

    /// A foreground deadline returns promptly even while the owned producer still awaits its remote operation.
    func testOwnedForegroundDeadlineDoesNotWaitOrFallback() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let cloud = ControlledRoutingProvider()
        var attempts: [RoutingAttempt] = []
        var cloudCalls = 0
        var localCalls = 0
        defer { cloud.release(); router.cancelCalibration() }
        let started = ContinuousClock.now
        do {
            for try await _ in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
                policy: .cloudRequired, deadline: .after(.milliseconds(30)), onAttempt: { attempts.append($0) },
                cloud: { RoutingProviderStream { continuation in cloudCalls += 1; continuation.yield(await cloud.call()) } },
                onDevice: { RoutingProviderStream { localCalls += 1; $0.yield("local") } }) {}
            XCTFail("Deadline must terminate the stream.")
        } catch RoutingRequestError.deadlineExceeded {}
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertFalse(cloud.released)
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(localCalls, 0)
        XCTAssertEqual(attempts.map(\.outcome), [.timedOut])
        cloud.release()
        await cloud.finished.wait()
    }

    /// Failure after partial foreground output cannot publish the already-running secondary answer as recovery.
    func testOwnedPartialOutputNeverSwitchesProviders() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        var updates: [String] = []
        var cloudCalls = 0
        var localCalls = 0
        do {
            for try await event in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { RoutingProviderStream { continuation in
                    cloudCalls += 1
                    continuation.yield("partial cloud")
                    throw URLError(.timedOut)
                } }, onDevice: { RoutingProviderStream { localCalls += 1; $0.yield("hidden local") } }) {
                if case .update(let value, let route) = event {
                    updates.append(value)
                    XCTAssertEqual(route, .cloud)
                }
                if case .completed = event { XCTFail("Partial-output errors cannot report success.") }
            }
            XCTFail("The provider error must propagate.")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        await router.waitForCalibration()
        XCTAssertEqual(updates, ["partial cloud"])
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertLessThanOrEqual(localCalls, 1)
    }

    /// A producer can close its continuation in cleanup and still throw before its work finishes.
    func testOwnedProducerFailureAfterNormalFinishRejectsPartialAnswer() async throws {
        let router = singleProviderRouter(monitorConnection: false, persistence: .memoryOnly)
        var updates: [String] = []
        var attempts: [RoutingAttempt] = []
        do {
            for try await event in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
                onAttempt: { attempts.append($0) }, cloud: {
                    RoutingProviderStream { continuation in
                        defer { continuation.finish() }
                        continuation.yield("incomplete")
                        throw URLError(.networkConnectionLost)
                    }
                }, onDevice: { XCTFail("Partial output prevents fallback."); return RoutingProviderStream { _ in } }) {
                if case .update(let text, _) = event { updates.append(text) }
                if case .completed = event { XCTFail("A partial answer must never report completion.") }
            }
            XCTFail("The producer's terminal error must reach its caller.")
        } catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        XCTAssertEqual(updates, ["incomplete"])
        XCTAssertEqual(attempts.map(\.outcome), [.failed])
        XCTAssertTrue(router.profile.samples.isEmpty)
    }

    /// An empty local stream can recover to cloud once without a second local generation.
    func testEmptyOwnedLocalStreamHasOneFallback() async throws {
        let profiles = try CostProfiles()
        defer { profiles.cleanup() }
        let scenario = CostScenario(policy: .automatic, paired: false, training: .localFaster,
            localReady: true, cloudReady: true, offline: false, capacity: 8_192, cloud: .success, local: .success)
        let router = try profiles.router(scenario)
        var cloudCalls = 0
        var localCalls = 0
        var result: RoutingResult<String>?
        for try await event in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
            workload: profiles.workload, cloud: { RoutingProviderStream { cloudCalls += 1; $0.yield("cloud") } },
            onDevice: { RoutingProviderStream { _ in localCalls += 1 } }) {
            if case .completed(let value) = event { result = value }
        }
        XCTAssertEqual(result?.value, "cloud")
        XCTAssertEqual(result?.attempts.map(\.route), [.onDevice, .cloud])
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(localCalls, 1)
    }
}
