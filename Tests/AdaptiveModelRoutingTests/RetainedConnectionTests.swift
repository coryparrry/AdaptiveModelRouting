import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Replays opaque network reassessment, real route transitions and quota-saving default local rechecks.
@MainActor
final class RetainedConnectionTests: XCTestCase {
    let wifi = PerformanceProfile.Connection(kind: .wifi)

    /// Only observable route/cost changes and explicit app invalidations discard historical priors.
    func testHistoryPolicyMatrix() {
        for changes in [[:], ["linkQuality": true], ["gatewaySet": false]] {
            XCTAssertFalse(RoutingConnectionObservation.shouldDiscardCloudHistory(previous: wifi,
                current: wifi, native: true, changes: changes))
        }
        for key in ["status", "availableInterfaceSet", "usedInterfaceTypes", "gatewaySet", "supportsIPv4",
            "supportsIPv6", "supportsDNS", "expensive", "constrained", "ultraConstrained", "localEndpoint", "remoteEndpoint"] {
            XCTAssertTrue(RoutingConnectionObservation.shouldDiscardCloudHistory(previous: wifi,
                current: wifi, native: true, changes: [key: true]), key)
        }
        XCTAssertTrue(RoutingConnectionObservation.shouldDiscardCloudHistory(previous: wifi,
            current: wifi, native: false, changes: [:]))
        XCTAssertTrue(RoutingConnectionObservation.shouldDiscardCloudHistory(previous: wifi,
            current: .init(kind: .cellular), native: true, changes: [:]))
    }

    /// Opaque updates retain old measurements but reject cloud work begun before the actual native inequality.
    func testOpaqueUpdateRetainsHistoryAndInvalidatesInflightObservation() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let now = ContinuousClock.now
        router.updateConnection(wifi, observedAt: now)
        _ = try await router.measure(model: .cloud, inputTokens: 100, snapshot: router.snapshot()) { "old" }
        let snapshot = router.snapshot()
        _ = try await router.measure(model: .cloud, inputTokens: 100, snapshot: snapshot) {
            router.applyConnectionObservation(self.wifi, native: true, nativeEqual: false, changes: [:],
                observedAt: now.advanced(by: .seconds(1)))
            return "spanned transition"
        }
        XCTAssertEqual(router.snapshot().generation, snapshot.generation + 1)
        XCTAssertEqual(router.profile.samples.count, 1)
        router.applyConnectionObservation(wifi, native: true, nativeEqual: false, changes: ["linkQuality": true],
            observedAt: now.advanced(by: .seconds(2)))
        XCTAssertEqual(router.profile.samples.count, 1)
        router.applyConnectionObservation(wifi, native: true, nativeEqual: false, changes: ["gatewaySet": true],
            observedAt: now.advanced(by: .seconds(3)))
        XCTAssertTrue(router.profile.samples.isEmpty)
    }

    /// Stale opaque notifications cannot supersede a current path or erase preserved priors.
    func testStaleOpaqueNotificationIsIgnored() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let now = ContinuousClock.now
        router.updateConnection(wifi, observedAt: now)
        _ = try await router.measure(model: .cloud, inputTokens: 100, snapshot: router.snapshot()) { "old" }
        let generation = router.snapshot().generation
        router.applyConnectionObservation(.init(kind: .cellular), native: true, nativeEqual: false,
            changes: ["status": true], observedAt: now.advanced(by: .seconds(-1)))
        XCTAssertEqual(router.snapshot().generation, generation)
        XCTAssertEqual(router.profile.samples.count, 1)
    }

    /// New defaults recheck free local inference on every eligible paid answer without probing PCC early.
    func testDefaultCadenceRechecksLocalAndPreservesExplicitFrequency() {
        var schedule = RoutingCalibrationSchedule()
        XCTAssertTrue(schedule.shouldProbe(required: false, configuration: .paired(), route: .onDevice,
            cloudInterval: 600, now: .now))
        schedule.recordCloudUse(at: .now)
        XCTAssertFalse(schedule.shouldProbe(required: true, configuration: .paired(), route: .cloud,
            cloudInterval: 600, now: .now))
        var explicit = RoutingCalibrationSchedule()
        for _ in 0..<9 {
            XCTAssertFalse(explicit.shouldProbe(required: false, configuration: .paired(refreshEvery: 10),
                route: .onDevice, cloudInterval: 600, now: .now))
        }
        XCTAssertTrue(explicit.shouldProbe(required: false, configuration: .paired(refreshEvery: 10),
            route: .onDevice, cloudInterval: 600, now: .now))
    }

    /// Faster current local evidence stops subsequent paid foreground work rather than waiting ten requests.
    func testDefaultSwitchBackUsesOnePaidRequest() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        var cloudTime = ContinuousClock.now
        var localTime = cloudTime
        router.measurementTime = { $0 == .cloud ? cloudTime : localTime }
        router.updateConnection(wifi)
        for _ in 0..<3 {
            _ = try await router.measure(model: .onDevice, inputTokens: 100, snapshot: router.snapshot()) {
                localTime = localTime.advanced(by: .milliseconds(80))
                return "full"
            }
            _ = try await router.measure(model: .cloud, inputTokens: 100, snapshot: router.snapshot()) {
                cloudTime = cloudTime.advanced(by: .milliseconds(40))
                return "full"
            }
        }
        var paid = 0
        var local = 0
        var routes: [InferenceRoute?] = []
        for _ in 0..<5 {
            let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8192,
                cloud: {
                    paid += 1
                    cloudTime = cloudTime.advanced(by: .milliseconds(20))
                    return "short"
                },
                onDevice: {
                    local += 1
                    localTime = localTime.advanced(by: .milliseconds(1))
                    return "short"
                })
            routes.append(result.route)
            await router.waitForCalibration()
        }
        XCTAssertEqual(routes.first!, .cloud)
        XCTAssertEqual(Array(routes.suffix(4)), Array(repeating: .onDevice, count: 4))
        XCTAssertEqual(paid, 1)
        XCTAssertEqual(local, 5)
    }
}
