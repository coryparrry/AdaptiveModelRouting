import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Makes quota preservation an explicit eligibility contract across all core generation entry points.
@MainActor
final class QuotaEligibilityTests: XCTestCase {
    /// Exhausted quota always blocks cloud; automatic conservation and optional calibration also respect warnings.
    func testQuotaEligibilityMatrix() async throws {
        let profiles = try CostProfiles(cloudAge: 601)
        defer { profiles.cleanup() }
        var cases = 0
        var failures: [String] = []
        for training in CostTraining.allCases {
            for quota in [CloudQuotaStatus.unknown, .available, .approachingLimit, .exhausted] {
                for conserve in [false, true] {
                    for policy in [RoutingPolicy.automatic, .localOnly, .cloudRequired] {
                        for localReady in [false, true] {
                            for cloudReady in [false, true] {
                                for fits in [false, true] {
                                    for api in 0..<3 {
                                        cases += 1
                                        let scenario = CostScenario(policy: policy, paired: true, training: training,
                                            localReady: localReady, cloudReady: cloudReady, offline: false,
                                            capacity: fits ? 8_192 : 499, cloud: .success, local: .success)
                                        let router = try profiles.router(scenario,
                                            configuration: .init(conserveCloudQuota: conserve))
                                        let ready = RoutingAvailability(onDevice: localReady, cloud: cloudReady, cloudQuota: quota)
                                        let calls = CostCalls()
                                        var result: RoutingResult<String>?
                                        if api == 0 {
                                            result = try await router.respondDetailed(inputTokens: 100,
                                                localContextCapacity: scenario.capacity, policy: policy,
                                                workload: profiles.workload, availability: ready,
                                                cloud: { try calls.generate(.cloud, outcome: .success) },
                                                onDevice: { try calls.generate(.onDevice, outcome: .success)! })
                                        } else {
                                            let events = api == 1
                                                ? router.streamOwned(inputTokens: 100, localContextCapacity: scenario.capacity,
                                                    policy: policy, workload: profiles.workload, availability: ready,
                                                    cloud: { calls.stream(.cloud, outcome: .success) },
                                                    onDevice: { calls.stream(.onDevice, outcome: .success) })
                                                : router.stream(inputTokens: 100, localContextCapacity: scenario.capacity,
                                                    policy: policy, workload: profiles.workload, availability: ready,
                                                    cloud: { calls.stream(.cloud, outcome: .success).stream },
                                                    onDevice: { calls.stream(.onDevice, outcome: .success).stream })
                                            for try await event in events {
                                                if case .completed(let value) = event { result = value }
                                            }
                                        }
                                        await router.waitForCalibration()
                                        let cloudAllowed = cloudReady && policy != .localOnly && quota != .exhausted
                                            && !(conserve && policy == .automatic && quota == .approachingLimit)
                                        let localAllowed = localReady && fits && policy != .cloudRequired
                                        let expected: InferenceRoute?
                                        if !cloudAllowed { expected = localAllowed ? .onDevice : nil }
                                        else if !localAllowed || training != .localFaster { expected = .cloud }
                                        else { expected = .onDevice }
                                        var errors: [String] = []
                                        if result == nil { errors.append("missing completed result") }
                                        if result?.route != expected { errors.append("wrong eligible provider") }
                                        if !cloudAllowed && calls.started[.cloud, default: 0] != 0 { errors.append("quota-forbidden cloud call") }
                                        if quota == .approachingLimit && expected == .onDevice
                                            && calls.started[.cloud, default: 0] != 0 { errors.append("optional near-quota PCC probe") }
                                        if calls.started.values.contains(where: { $0 > 1 }) { errors.append("duplicate provider call") }
                                        if !errors.isEmpty {
                                            failures.append("case=\(cases),api=\(api),quota=\(quota),conserve=\(conserve),\(scenario.label): \(errors)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cases, 1_728)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(12))")
        print("Quota eligibility matrix: \(cases) cases, \(failures.count) failures")
    }

    /// The low-level executor preserves cloud-only requirements even without the higher-level eligibility mask.
    func testDirectExecutorCloudRequiredNilCannotSpendLocal() async throws {
        for preferred in [InferenceRoute.cloud, .onDevice] {
            var cloudCalls = 0
            var localCalls = 0
            let result: String? = try await InferenceExecutor.respond(preferred: preferred, canUseLocalWhole: true,
                policy: .cloudRequired, cloud: { cloudCalls += 1; return nil },
                onDevice: { localCalls += 1; return "local" })
            XCTAssertNil(result)
            XCTAssertEqual(cloudCalls, 1)
            XCTAssertEqual(localCalls, 0)
        }
    }

    /// An already-dispatched fallback belongs to its original caller rather than a later request's quota state.
    func testAnotherRequestCannotCancelCloudAlreadyUsedForForegroundRecovery() async throws {
        for localOnly in [false, true] {
            let profiles = try CostProfiles(cloudAge: 601)
            defer { profiles.cleanup() }
            let scenario = CostScenario(policy: .automatic, paired: true, training: .localFaster,
                localReady: true, cloudReady: true, offline: false, capacity: 8_192, cloud: .success, local: .success)
            let router = try profiles.router(scenario)
            let cloud = ControlledRoutingProvider()
            let recovering = RoutingTestSignal()
            var cloudCalls = 0
            defer { cloud.release(); router.cancelCalibration() }
            let first = Task<RoutingResult<String>, any Error> {
                try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                    workload: profiles.workload, onAttempt: {
                        if $0.route == .onDevice && $0.outcome == .failed { recovering.signal() }
                    }, cloud: { cloudCalls += 1; return await cloud.call() }, onDevice: {
                        await cloud.started.wait()
                        throw URLError(.timedOut)
                    })
            }
            await recovering.wait()
            let second = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                policy: localOnly ? .localOnly : .automatic, workload: profiles.workload,
                availability: .init(cloudQuota: localOnly ? .available : .approachingLimit),
                cloud: { cloudCalls += 1; return "unexpected extra cloud" }, onDevice: { "second local" })
            XCTAssertEqual(second.value, "second local")
            cloud.release("first recovered")
            let result = try await first.value
            XCTAssertEqual(result.value, "first recovered")
            XCTAssertEqual(result.route, .cloud)
            XCTAssertTrue(result.didFallback)
            XCTAssertEqual(cloudCalls, 1)
            await router.waitForCalibration()
        }
    }

    /// A private request arriving before promotion leaves the existing automatic caller's recovery available.
    func testLocalOnlyRequestBeforeFallbackPreservesRunningProbe() async throws {
        let profiles = try CostProfiles(cloudAge: 601)
        defer { profiles.cleanup() }
        let scenario = CostScenario(policy: .automatic, paired: true, training: .localFaster,
            localReady: true, cloudReady: true, offline: false, capacity: 8_192, cloud: .success, local: .success)
        let router = try profiles.router(scenario)
        let cloud = ControlledRoutingProvider()
        var cloudCalls = 0
        defer { cloud.release(); router.cancelCalibration() }
        let result: RoutingResult<String> = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            workload: profiles.workload, cloud: { cloudCalls += 1; return await cloud.call() }, onDevice: {
                await cloud.started.wait()
                let second = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                    policy: .localOnly, workload: profiles.workload,
                    cloud: { XCTFail("The private request must remain local."); return "unexpected" },
                    onDevice: { "private" })
                XCTAssertEqual(second.value, "private")
                cloud.release("recovered")
                throw URLError(.networkConnectionLost)
            })
        XCTAssertEqual(result.value, "recovered")
        XCTAssertEqual(result.attempts.map(\.route), [.onDevice, .cloud])
        XCTAssertEqual(cloudCalls, 1)
    }

    /// Intervening cloud use blocks the queued optional call while still allowing a genuine foreground retry.
    func testQueuedCloudProbeRechecksCooldownWithoutBlockingRecovery() async throws {
        for localFails in [false, true] {
            let profiles = try CostProfiles(cloudAge: 601)
            defer { profiles.cleanup() }
            let scenario = CostScenario(policy: .automatic, paired: true, training: .localFaster,
                localReady: true, cloudReady: true, offline: false, capacity: 8_192, cloud: .success, local: .success)
            let router = try profiles.router(scenario)
            var cloudCalls = 0
            let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                workload: profiles.workload, cloud: { cloudCalls += 1; return "recovered" }, onDevice: {
                    XCTAssertTrue(router.isCalibrating)
                    _ = try await router.measure(model: .cloud, inputTokens: 100, snapshot: router.snapshot()) { "other request" }
                    if localFails { throw URLError(.networkConnectionLost) }
                    return "local"
                })
            await router.waitForCalibration()
            XCTAssertEqual(result.value, localFails ? "recovered" : "local")
            XCTAssertEqual(cloudCalls, localFails ? 1 : 0)
            XCTAssertEqual(result.attempts.map(\.route), localFails ? [.onDevice, .cloud] : [.onDevice])
            XCTAssertNil(router.lastCalibrationAttempt, "A skipped optional call has no provider attempt.")
        }
    }

    /// New quota pressure cancels only optional cloud work while retaining its execution slot until exit.
    func testQuotaWarningStopsAnAlreadyRunningCloudProbe() async throws {
        for policy in [RoutingPolicy.automatic, .localOnly] {
            let profiles = try CostProfiles(cloudAge: 601)
            defer { profiles.cleanup() }
            let scenario = CostScenario(policy: .automatic, paired: true, training: .localFaster,
                localReady: true, cloudReady: true, offline: false, capacity: 8_192, cloud: .success, local: .success)
            let router = try profiles.router(scenario)
            let cloud = ControlledRoutingProvider()
            var cloudCalls = 0
            defer { cloud.release(); router.cancelCalibration() }
            let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                workload: profiles.workload, cloud: { cloudCalls += 1; return await cloud.call() }, onDevice: { "local" })
            await cloud.started.wait()
            let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                policy: policy, workload: profiles.workload, availability: .init(cloudQuota: .approachingLimit),
                cloud: { cloudCalls += 1; return "unexpected cloud" }, onDevice: { "local" })
            await router.waitForCalibration()
            XCTAssertEqual(result.route, .onDevice)
            XCTAssertEqual(result.decision.reason, policy == .localOnly ? .localOnly : .cloudQuotaConserved)
            XCTAssertEqual(cloudCalls, 1)
            XCTAssertEqual(router.lastCalibrationAttempt?.outcome, .cancelled)
            XCTAssertTrue(router.isCalibrating)
            cloud.release()
            await cloud.finished.wait()
        }
    }
}
