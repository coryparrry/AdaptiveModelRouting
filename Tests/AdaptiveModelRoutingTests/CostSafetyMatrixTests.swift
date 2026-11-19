import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Verifies dispatch budgets against a policy/outcome contract across every declared matrix combination.
@MainActor
final class CostSafetyMatrixTests: XCTestCase {
    /// Runs text requests through the full public API, including background work and fallback.
    func testTextDispatchMatrix() async throws { try await runMatrix(streaming: false) }

    /// Runs the same contract through owned streaming, including empty streams and producer errors.
    func testOwnedStreamingDispatchMatrix() async throws { try await runMatrix(streaming: true) }

    /// The compatibility bare-stream entry point preserves every dispatch policy and budget too.
    func testLegacyStreamingDispatchMatrix() async throws { try await runMatrix(streaming: true, legacy: true) }

    /// A cancelled worker can outlive its result, then free the slot during matrix cleanup.
    func testMatrixCleanupWaitsForCancelledWorkerExit() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let worker = ControlledRoutingProvider()
        defer { worker.release(); router.cancelCalibration() }
        _ = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { await worker.started.wait(); return "cloud" }, onDevice: { await worker.call() })
        router.cancelCalibration()
        await router.waitForCalibration()
        let releasedWhileBlocked = try await waitForSlotRelease(router, timeout: .milliseconds(5))
        XCTAssertFalse(releasedWhileBlocked, "Cleanup must report a worker that stays occupied past its budget.")
        Task { worker.release() }
        let released = try await waitForSlotRelease(router)
        XCTAssertTrue(released, "A worker exiting during cleanup must count as released.")
    }

    /// Allows a cancelled fixture to unwind before reading final counts, with a deadline for a stuck worker.
    private func waitForSlotRelease(_ router: AdaptiveRouter, timeout: Duration = .seconds(2)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while router.isCalibrating {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    /// Collects failures by scenario so one mismatch cannot hide untested remaining combinations.
    private func runMatrix(streaming: Bool, legacy: Bool = false) async throws {
        let profiles = try CostProfiles()
        defer { profiles.cleanup() }
        let scenarios = CostScenario.all()
        var failures: [[String: Any]] = []
        var cloudStarts = 0
        var localStarts = 0
        var maximumCalls = 0
        for (index, scenario) in scenarios.enumerated() {
            let router = try profiles.router(scenario)
            let calls = CostCalls()
            var actual = "none"
            var completed: RoutingResult<String>?
            do {
                if streaming {
                    let events = legacy
                        ? router.stream(inputTokens: 100, localContextCapacity: scenario.capacity,
                            policy: scenario.policy, workload: profiles.workload,
                            availability: .init(onDevice: scenario.localReady, cloud: scenario.cloudReady),
                            shouldFallback: { calls.classify($0, error: $1) },
                            cloud: { calls.stream(.cloud, outcome: scenario.cloud).stream },
                            onDevice: { calls.stream(.onDevice, outcome: scenario.local).stream })
                        : router.streamOwned(inputTokens: 100, localContextCapacity: scenario.capacity,
                            policy: scenario.policy, workload: profiles.workload,
                            availability: .init(onDevice: scenario.localReady, cloud: scenario.cloudReady),
                            shouldFallback: { calls.classify($0, error: $1) },
                            cloud: { calls.stream(.cloud, outcome: scenario.cloud) },
                            onDevice: { calls.stream(.onDevice, outcome: scenario.local) })
                    for try await event in events {
                        if case .completed(let result) = event { completed = result }
                    }
                } else {
                    completed = try await router.respondDetailed(inputTokens: 100, localContextCapacity: scenario.capacity,
                        policy: scenario.policy, workload: profiles.workload,
                        availability: .init(onDevice: scenario.localReady, cloud: scenario.cloudReady),
                        shouldFallback: { calls.classify($0, error: $1) }, cloud: {
                            calls.dispatched[.cloud, default: 0] += 1
                            return try calls.generate(.cloud, outcome: scenario.cloud)
                        }, onDevice: {
                            calls.dispatched[.onDevice, default: 0] += 1
                            return try calls.generate(.onDevice, outcome: scenario.local)!
                        })
                }
                if let route = completed?.route { actual = "value.\(route.rawValue)" }
            } catch { actual = costError(error) }
            await router.waitForCalibration()
            let slotReleased = try await waitForSlotRelease(router)
            let cloud = calls.started[.cloud, default: 0]
            let local = calls.started[.onDevice, default: 0]
            cloudStarts += cloud
            localStarts += local
            maximumCalls = max(maximumCalls, cloud + local)
            var violations: [String] = []
            if actual != scenario.expected { violations.append("expected \(scenario.expected), got \(actual)") }
            if cloud > 1 || local > 1 { violations.append("Provider invoked more than once: cloud=\(cloud),local=\(local)") }
            if calls.dispatched.values.contains(where: { $0 > 1 }) { violations.append("Duplicate provider dispatch") }
            if calls.classified.values.contains(where: { $0 > 1 }) { violations.append("Duplicate error classification") }
            for route in [InferenceRoute.cloud, .onDevice] {
                if !scenario.permittedCalls.contains(route) && calls.dispatched[route, default: 0] != 0 {
                    violations.append("Unbudgeted \(route.rawValue) dispatch: no probe/recovery authorized")
                }
                if scenario.requiredCalls.contains(route) && calls.started[route, default: 0] != 1 {
                    violations.append("Missing required \(route.rawValue) generation")
                }
            }
            if (!scenario.cloudReady || scenario.policy == .localOnly) && cloud != 0 { violations.append("Forbidden cloud call") }
            if (!scenario.localAllowed || scenario.policy == .cloudRequired) && local != 0 { violations.append("Forbidden local call") }
            if let result = completed {
                if result.attempts.count > 2 { violations.append("More than two foreground attempts") }
                if result.value != nil && result.value != result.route?.rawValue { violations.append("Output provider differs from reported route") }
            }
            if !slotReleased { violations.append("Completed synthetic provider left its slot occupied") }
            if !violations.isEmpty {
                failures.append(["index": index, "scenario": scenario.label, "violations": violations,
                    "cloudStarts": cloud, "localStarts": local])
            }
        }
        try evidence(name: legacy ? "legacy-stream-matrix" : streaming ? "owned-stream-matrix" : "text-matrix",
            payload: ["cases": scenarios.count, "failures": failures, "cloudStarts": cloudStarts,
                      "localStarts": localStarts, "maximumProviderStartsPerRequest": maximumCalls])
        XCTAssertEqual(scenarios.count, 8_640)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failing cases: \(failures.prefix(12))")
    }

    /// Saves attributable, configuration-specific evidence without printing thousands of successful assertions.
    private func evidence(name: String, payload: [String: Any]) throws {
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/cost-safety")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("\(configuration)-\(name).json"))
        print("Cost safety \(name): \(payload["cases"] ?? 0) cases, \((payload["failures"] as? [Any])?.count ?? 0) failures")
    }
}
