import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Simulates inaccessible network handoffs and interruptions without changing the host network or calling models.
@MainActor
final class NetworkLifecycleSimulationTests: XCTestCase {
    /// Replays route, cost, opaque, duplicate and stale updates while an old cloud timing is in flight.
    func testHandoffMatrixPreservesQuotaAndRejectsStaleCloudTimings() async throws {
        let wifi = PerformanceProfile.Connection(kind: .wifi)
        let hotspot = PerformanceProfile.Connection(kind: .wifi, expensive: true)
        let mobile = PerformanceProfile.Connection(kind: .cellular, expensive: true)
        let wired = PerformanceProfile.Connection(kind: .wired)
        let cases: [(String, PerformanceProfile.Connection, Bool, [String: Bool], Int, Bool, Int)] = [
            ("different Wi-Fi gateway", wifi, false, ["gatewaySet": true], 1, true, 3),
            ("hotspot", hotspot, false, ["expensive": true], 1, true, 3),
            ("cellular", mobile, false, ["usedInterfaceTypes": true], 1, true, 3),
            ("Ethernet", wired, false, ["usedInterfaceTypes": true], 1, true, 3),
            ("offline", .init(kind: .offline), false, ["status": true], 1, true, 0),
            ("opaque", wifi, false, [:], 1, true, 0),
            ("link quality", wifi, false, ["linkQuality": true], 1, true, 0),
            ("duplicate", wifi, true, [:], 1, false, 0),
            ("stale", mobile, false, ["gatewaySet": true], -1, false, 0)
        ]
        for (name, target, equal, changes, offset, advanced, removed) in cases {
            let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var profile = PerformanceProfile()
            for index in 0..<3 {
                let date = Date.now.addingTimeInterval(Double(index - 3))
                for connection in [wifi, hotspot, mobile, wired] {
                    profile.record(model: .cloud, tokens: 100, seconds: 2, connection: connection, now: date)
                }
                profile.record(model: .onDevice, tokens: 100, seconds: 0.25, connection: wifi, now: date)
            }
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
            let file = directory.appendingPathComponent("latency.json")
            try JSONSerialization.data(withJSONObject: ["version": 1, "system": "network-lifecycle-simulation",
                "profile": encoded, "lastCloudUse": Date.now.timeIntervalSinceReferenceDate]).write(to: file)
            let router = AdaptiveRouter(directory: directory, system: "network-lifecycle-simulation", monitorConnection: false)
            let now = ContinuousClock.now
            router.updateConnection(wifi, observedAt: now)
            let snapshot = router.snapshot()
            let provider = ControlledRoutingProvider()
            let request = Task {
                try await router.measure(model: .cloud, inputTokens: 100, snapshot: snapshot) { await provider.call() }
            }
            await provider.started.wait()
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            router.applyConnectionObservation(target, native: true, nativeEqual: equal, changes: changes,
                observedAt: now.advanced(by: .seconds(offset)))
            provider.release()
            _ = try await request.value
            XCTAssertEqual(router.snapshot().generation, snapshot.generation + (advanced ? 1 : 0), name)
            XCTAssertEqual(router.profile.samples.filter { $0.model == .cloud }.count, 12 - removed + (advanced ? 0 : 1), name)
            XCTAssertEqual(router.profile.samples.filter { $0.model == .onDevice }.count, 3, name)
            var cloudCalls = 0
            var localCalls = 0
            for _ in 0..<3 {
                let result = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                    cloud: { cloudCalls += 1; return "cloud" }, onDevice: { localCalls += 1; return "local" })
                await router.waitForCalibration()
                XCTAssertEqual(result.route, .onDevice, name)
            }
            let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertEqual(before["lastCloudUse"] as? Double, after["lastCloudUse"] as? Double, name)
            XCTAssertEqual(cloudCalls, 0, name)
            XCTAssertEqual(localCalls, 3, name)
        }
        print("Simulated handoffs: 9 scenarios, 27 following local requests, zero additional cloud calls")
    }

    /// Caller cancellation during a handoff cannot fallback or admit late non-cooperative provider work.
    func testHandoffAndCallerCancellationForBufferedAndOwnedStreams() async throws {
        for streaming in [false, true] {
            let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
            let wifi = PerformanceProfile.Connection(kind: .wifi)
            let now = ContinuousClock.now
            router.updateConnection(wifi, observedAt: now)
            let provider = ControlledRoutingProvider()
            var cloudCalls = 0
            var localCalls = 0
            let request = Task {
                if streaming {
                    for try await _ in router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
                        availability: .init(onDevice: false), cloud: {
                            RoutingProviderStream { continuation in
                                cloudCalls += 1
                                continuation.yield(await provider.call())
                            }
                        }, onDevice: {
                            RoutingProviderStream { continuation in localCalls += 1; continuation.yield("local") }
                        }) {}
                } else {
                    _ = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                        availability: .init(onDevice: false), cloud: { cloudCalls += 1; return await provider.call() },
                        onDevice: { localCalls += 1; return "local" })
                }
            }
            await provider.started.wait()
            router.applyConnectionObservation(wifi, native: true, nativeEqual: false, changes: ["gatewaySet": true],
                observedAt: now.advanced(by: .seconds(1)))
            request.cancel()
            provider.release()
            do { try await request.value; XCTAssertTrue(streaming, "Buffered cancellation must remain an error") }
            catch is CancellationError {}
            await provider.finished.wait()
            await router.waitForCalibration()
            XCTAssertEqual(cloudCalls, 1)
            XCTAssertEqual(localCalls, 0)
            XCTAssertTrue(router.profile.samples.isEmpty)
            XCTAssertTrue(router.profile.failures.isEmpty)
        }
    }
}
