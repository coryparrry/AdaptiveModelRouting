import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Verifies calibration lifecycle, disk opt-out and recovery without touching unrelated user data.
@MainActor
final class ProfileControlTests: XCTestCase {
    /// Mimics a provider retry hint without invoking a model or coupling persistence tests to the Apple SDK.
    private struct Throttle: RoutingRetryAfterProviding {
        let routingRetryAfter: Date?
    }

    /// Enabling disk honors the longest provider deadline learned in either storage mode.
    func testEnablingDiskMergesProviderDeadlinesAndPaidPacing() async throws {
        for diskHasLaterDeadline in [true, false] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let earlier = Date.now.addingTimeInterval(300)
            let later = earlier.addingTimeInterval(600)
            let disk = singleProviderRouter(directory: directory, monitorConnection: false)
            let memory = singleProviderRouter(directory: directory, monitorConnection: false, persistence: .memoryOnly)
            for (router, deadline) in [(memory, diskHasLaterDeadline ? earlier : later),
                                       (disk, diskHasLaterDeadline ? later : earlier)] {
                do {
                    let _: Int = try await router.measure(model: .cloud, inputTokens: 1, snapshot: router.snapshot()) {
                        throw Throttle(routingRetryAfter: deadline)
                    }
                    XCTFail("Expected throttling")
                } catch is Throttle {}
            }
            let file = directory.appendingPathComponent("latency.json")
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            try memory.setPersistence(.disk)
            let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertEqual(after["lastCloudUse"] as? Double, before["lastCloudUse"] as? Double)
            XCTAssertEqual(try XCTUnwrap(after["cloudRetryAfter"] as? Double), later.timeIntervalSinceReferenceDate, accuracy: 0.001)
            for router in [memory, singleProviderRouter(directory: directory, monitorConnection: false)] {
                let result = try await router.respondDetailed(inputTokens: 1, localContextCapacity: 8192, policy: .cloudRequired,
                    cloud: { XCTFail("Provider must honor retained retry deadline"); return 1 }, onDevice: { 2 })
                XCTAssertEqual(result.status, .unavailable)
            }
        }
    }

    /// A protected cache can be reopened after unlock without losing a throttle or blocking local work.
    func testTemporaryCacheReadFailureRecoversOnUnlock() async throws {
        for startInMemory in [false, true] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let disk = singleProviderRouter(directory: directory, monitorConnection: false)
            do {
                let _: Int = try await disk.measure(model: .cloud, inputTokens: 1, snapshot: disk.snapshot()) {
                    throw Throttle(routingRetryAfter: .now.addingTimeInterval(600))
                }
                XCTFail("Expected throttling")
            } catch is Throttle {}

            let file = directory.appendingPathComponent("latency.json")
            let original = try Data(contentsOf: file)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            let router = singleProviderRouter(directory: directory, monitorConnection: false,
                persistence: startInMemory ? .memoryOnly : .disk)
            if startInMemory { try router.setPersistence(.disk) }
            XCTAssertEqual(router.storageStatus, .unavailable)
            XCTAssertThrowsError(try router.resetProfile())
            XCTAssertThrowsError(try router.setPersistence(.memoryOnly))
            XCTAssertEqual(router.persistence, .disk)

            let blocked = try await router.respondDetailed(inputTokens: 1, localContextCapacity: 8192, policy: .cloudRequired,
                cloud: { XCTFail("The saved deadline is unreadable"); return 1 }, onDevice: { 2 })
            XCTAssertEqual(blocked.status, .unavailable)
            let local = try await router.respond(inputTokens: 1, localContextCapacity: 8192,
                cloud: { XCTFail("Local inference can serve while storage is locked"); return 1 }, onDevice: { 2 })
            XCTAssertEqual(local, 2)

            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertEqual(try Data(contentsOf: file), original)
            let throttled = try await router.respondDetailed(inputTokens: 1, localContextCapacity: 8192, policy: .cloudRequired,
                cloud: { XCTFail("Recovered owner must respect the stored deadline"); return 1 }, onDevice: { 2 })
            XCTAssertEqual(throttled.status, .unavailable)
            XCTAssertEqual(router.storageStatus, .notPersisted)
            let resumed = try await router.respond(inputTokens: 1, localContextCapacity: 8192,
                cloud: { XCTFail("Still throttled"); return 1 }, onDevice: { 2 })
            XCTAssertEqual(resumed, 2)
            XCTAssertEqual(router.storageStatus, .persisted)
            let reloaded = singleProviderRouter(directory: directory, monitorConnection: false)
            XCTAssertEqual(reloaded.profile.samples.count, 2, "Preserve local learning from before and after unlock")
            try router.resetProfile()
            let reset = singleProviderRouter(directory: directory, monitorConnection: false)
            let afterReset = try await reset.respondDetailed(inputTokens: 1, localContextCapacity: 8192, policy: .cloudRequired,
                cloud: { XCTFail("The recovered deadline must survive a reset"); return 1 }, onDevice: { 2 })
            XCTAssertEqual(afterReset.status, .unavailable)
        }
    }

    /// A non-clearing opt-out detaches a locked cache even when an earlier cloud call still owes a retry hint.
    func testDetachFromUnreadableCachePreventsLateWrites() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = singleProviderRouter(directory: directory, monitorConnection: false)
        _ = try await disk.measure(model: .onDevice, inputTokens: 3, snapshot: disk.snapshot()) { 1 }
        let file = directory.appendingPathComponent("latency.json")
        let original = try Data(contentsOf: file)
        let router = singleProviderRouter(directory: directory, monitorConnection: false, persistence: .memoryOnly)
        let provider = ControlledRoutingProvider()
        let request = Task {
            try await router.respond(inputTokens: 1, localContextCapacity: 8192, policy: .cloudRequired, cloud: {
                _ = await provider.call()
                throw Throttle(routingRetryAfter: .now.addingTimeInterval(600))
            }, onDevice: { 2 })
        }
        defer { provider.release() }
        await provider.started.wait()
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        try router.setPersistence(.disk)
        XCTAssertEqual(router.storageStatus, .unavailable)
        try router.setPersistence(.memoryOnly, clearExistingCache: false)
        XCTAssertEqual(router.persistence, .memoryOnly)
        XCTAssertEqual(router.storageStatus, .memoryOnly)
        XCTAssertThrowsError(try router.setPersistence(.memoryOnly))
        XCTAssertEqual(router.storageStatus, .memoryOnly)
        try router.resetProfile()

        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let blocked = try await router.respondDetailed(inputTokens: 1, localContextCapacity: 8192, policy: .cloudRequired,
            cloud: { XCTFail("Detached owner cannot check previous pacing"); return 1 }, onDevice: { 2 })
        XCTAssertEqual(blocked.status, .unavailable)
        provider.release()
        do { _ = try await request.value; XCTFail("Expected the late throttle") }
        catch is Throttle {}
        XCTAssertEqual(router.storageStatus, .memoryOnly)
        XCTAssertEqual(try Data(contentsOf: file), original)

        try router.setPersistence(.disk)
        let restored = singleProviderRouter(directory: directory, monitorConnection: false)
        let throttled = try await restored.respondDetailed(inputTokens: 1, localContextCapacity: 8192, policy: .cloudRequired,
            cloud: { XCTFail("Reattaching disk must persist the late in-memory throttle"); return 1 }, onDevice: { 2 })
        XCTAssertEqual(throttled.status, .unavailable)
    }

    /// A clean owner restores saved timings and resumes eligible cloud requests on its first read after unlock.
    func testUnlockRestoresPristineProfileAndUnthrottledCloud() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = singleProviderRouter(directory: directory, monitorConnection: false)
        _ = try await disk.measure(model: .onDevice, inputTokens: 3, snapshot: disk.snapshot()) { 1 }
        let file = directory.appendingPathComponent("latency.json")
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let owner = singleProviderRouter(directory: directory, monitorConnection: false)
        XCTAssertEqual(owner.storageStatus, .unavailable)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let result = try await owner.respond(inputTokens: 1, localContextCapacity: 8192, policy: .cloudRequired,
            cloud: { 1 }, onDevice: { XCTFail("Requested cloud explicitly"); return 2 })
        XCTAssertEqual(result, 1)
        XCTAssertEqual(owner.profile.samples.map(\.model), [.onDevice, .cloud])
        XCTAssertEqual(owner.storageStatus, .persisted)
    }

    /// First path admission retains old timings; a later material change drops only the affected cloud path.
    func testUnlockMergesLiveTimingsAndAppliesOnlyMaterialPathInvalidations() async throws {
        for invalidateWiFi in [false, true] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let disk = singleProviderRouter(directory: directory, monitorConnection: false, calibrationIdentifier: "model")
            disk.updateConnection(.init(kind: .wifi))
            _ = try await disk.measure(model: .onDevice, inputTokens: 100, snapshot: disk.snapshot()) { 1 }
            _ = try await disk.measure(model: .cloud, inputTokens: 101, snapshot: disk.snapshot()) { 1 }
            disk.updateConnection(.init(kind: .wired))
            _ = try await disk.measure(model: .cloud, inputTokens: 102, snapshot: disk.snapshot()) { 1 }
            do {
                let _: Int = try await disk.measure(model: .onDevice, inputTokens: 1, snapshot: disk.snapshot()) {
                    throw URLError(.timedOut)
                }
                XCTFail("Expected the local failure")
            } catch is URLError {}

            let file = directory.appendingPathComponent("latency.json")
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            let owner = singleProviderRouter(directory: directory, monitorConnection: false)
            owner.updateConnection(.init(kind: .wifi))
            owner.updateCalibrationIdentifier("model")
            if invalidateWiFi {
                owner.updateConnection(.init(kind: .cellular))
                owner.updateConnection(.init(kind: .wifi))
            }
            _ = try await owner.measure(model: .onDevice, inputTokens: 200, snapshot: owner.snapshot()) { 1 }
            XCTAssertEqual(owner.storageStatus, .unavailable)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            _ = try await owner.measure(model: .onDevice, inputTokens: 300, snapshot: owner.snapshot()) { 1 }

            let reopened = singleProviderRouter(directory: directory, monitorConnection: false, calibrationIdentifier: "model")
            let expected = invalidateWiFi ? [100, 102, 200, 300] : [100, 101, 102, 200, 300]
            XCTAssertEqual(reopened.profile.samples.map(\.tokens), expected)
            XCTAssertTrue(reopened.profile.failures.isEmpty, "New local successes cleared the old local failure.")
        }
    }

    /// Reapplying disk storage preserves a pending restore; first enabling it keeps the memory owner's timings.
    func testSettingDiskWhileCacheIsLockedRespectsOriginalStorageMode() async throws {
        for initialMode in [RoutingPersistence.disk, .memoryOnly] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = singleProviderRouter(directory: directory, monitorConnection: false)
            _ = try await original.measure(model: .onDevice, inputTokens: 100, snapshot: original.snapshot()) { 1 }

            let file = directory.appendingPathComponent("latency.json")
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            let owner = singleProviderRouter(directory: directory, monitorConnection: false, persistence: initialMode)
            owner.updateConnection(.init(kind: .wifi))
            _ = try await owner.measure(model: .onDevice, inputTokens: 200, snapshot: owner.snapshot()) { 1 }
            try owner.setPersistence(.disk)
            XCTAssertEqual(owner.storageStatus, .unavailable)

            // Switching away from a demo mode temporarily detaches its retained owner.
            try owner.setPersistence(.memoryOnly, clearExistingCache: false)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try owner.setPersistence(.disk)
            _ = try await owner.measure(model: .onDevice, inputTokens: 300, snapshot: owner.snapshot()) { 1 }
            let reopened = singleProviderRouter(directory: directory, monitorConnection: false)
            XCTAssertEqual(reopened.profile.samples.map(\.tokens), initialMode == .disk ? [100, 200, 300] : [200, 300])
        }
    }

    /// Superseding a known identity while locked never restores the explicitly abandoned timings, even on a round trip.
    func testUnlockDoesNotRestoreAnExplicitlyInvalidatedProfile() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = singleProviderRouter(directory: directory, monitorConnection: false, calibrationIdentifier: "first")
        _ = try await disk.measure(model: .onDevice, inputTokens: 100, snapshot: disk.snapshot()) { 1 }

        let file = directory.appendingPathComponent("latency.json")
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let owner = singleProviderRouter(directory: directory, monitorConnection: false, calibrationIdentifier: "first")
        owner.updateCalibrationIdentifier("second")
        owner.updateCalibrationIdentifier("first")
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try await owner.measure(model: .onDevice, inputTokens: 200, snapshot: owner.snapshot()) { 1 }
        let reopened = singleProviderRouter(directory: directory, monitorConnection: false, calibrationIdentifier: "first")
        XCTAssertEqual(reopened.profile.samples.map(\.tokens), [200])
    }

    /// A failed replacement while throttled leaves the profile usable and reports the reset failure.
    func testFailedThrottledResetPreservesProfile() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = singleProviderRouter(directory: directory, monitorConnection: false)
        _ = try await router.measure(model: .onDevice, inputTokens: 1, snapshot: router.snapshot()) { 1 }
        do {
            let _: Int = try await router.measure(model: .cloud, inputTokens: 1, snapshot: router.snapshot()) {
                throw Throttle(routingRetryAfter: .now.addingTimeInterval(600))
            }
            XCTFail("Expected throttling")
        } catch is Throttle {}
        let cache = directory.appendingPathComponent("latency.json")
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let sibling = cache.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)
        XCTAssertThrowsError(try router.resetProfile())
        XCTAssertEqual(router.profile.samples.count, 1)
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
    }
    /// Default app namespaces differ even when two unsandboxed consumers select the same workload name.
    func testApplicationNamespacesAreDeterministicAndSeparate() {
        let root = URL(fileURLWithPath: "/private/tmp/calibration-root", isDirectory: true)
        let first = RoutingFingerprint.cacheDirectory(application: "dev.example.first", root: root)
        let other = RoutingFingerprint.cacheDirectory(application: "dev.example.other", root: root)
        XCTAssertEqual(first, RoutingFingerprint.cacheDirectory(application: "dev.example.first", root: root))
        XCTAssertNotEqual(first, other)
        XCTAssertFalse(first.lastPathComponent.contains("dev.example.first"))
    }
    /// Allocates an isolated owned cache directory for filesystem assertions.
    private func directory() throws -> URL {
        let value = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    /// Memory-only routers neither load nor overwrite an existing cache, including on reset.
    func testMemoryOnlyDoesNotTouchDisk() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("latency.json")
        let original = Data("unreadable preserved cache".utf8)
        try original.write(to: file)
        let router = singleProviderRouter(directory: directory, monitorConnection: false, persistence: .memoryOnly)
        let result = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { "cloud" }, onDevice: { "local" })
        XCTAssertEqual(result, "cloud")
        XCTAssertEqual(router.profile.samples.count, 1)
        XCTAssertEqual(router.storageStatus, .memoryOnly)
        try router.resetProfile()
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    /// Reset clears only the owned metadata file and invalidates requests that started before the reset.
    func testResetPreservesSiblingFilesAndRejectsInflightTraining() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sibling = directory.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: sibling)
        let router = singleProviderRouter(directory: directory, monitorConnection: false)
        let _: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { "first" }, onDevice: { "local" })
        let provider = ControlledRoutingProvider()
        let request = Task { try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { await provider.call() }, onDevice: { "local" }) }
        await provider.started.wait()
        try router.resetProfile()
        provider.release("valid old result")
        let result = try await request.value
        XCTAssertEqual(result, "valid old result")
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("latency.json").path))
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "keep")
    }

    /// Disabling persistence removes saved calibration by default, and reenabling saves current in-memory metadata.
    func testPersistenceCanBeChangedAtRuntime() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("latency.json")
        let router = singleProviderRouter(directory: directory, monitorConnection: false)
        let _: Int? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192, cloud: { 1 }, onDevice: { 2 })
        XCTAssertEqual(router.storageStatus, .persisted)
        try router.setPersistence(.memoryOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let _: Int? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192, cloud: { 1 }, onDevice: { 2 })
        XCTAssertEqual(router.profile.samples.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try router.setPersistence(.disk)
        XCTAssertEqual(router.storageStatus, .persisted)
        let restored = singleProviderRouter(directory: directory, monitorConnection: false)
        XCTAssertEqual(restored.profile.samples.count, 2)
    }

    /// Enabling disk after a memory-only start preserves an unknown existing format until explicit reset.
    func testEnablingDiskPreservesUnreadableCache() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("latency.json")
        let original = Data("future cache format".utf8)
        try original.write(to: file)
        let router = singleProviderRouter(directory: directory, monitorConnection: false, persistence: .memoryOnly)
        let _: Int? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192, cloud: { 1 }, onDevice: { 2 })
        try router.setPersistence(.disk)
        XCTAssertEqual(router.storageStatus, .preservedCache)
        XCTAssertEqual(try Data(contentsOf: file), original)
        try router.resetProfile()
        let _: Int? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192, cloud: { 1 }, onDevice: { 2 })
        XCTAssertEqual(router.storageStatus, .persisted)
    }

    /// Equal calibration identities reuse timings while changed identities reset without storing raw identifiers.
    func testCalibrationIdentityInvalidatesAndIsHashed() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identifier = "private instructions and model identity"
        let router = singleProviderRouter(directory: directory, monitorConnection: false, calibrationIdentifier: identifier)
        let _: Int? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192, cloud: { 1 }, onDevice: { 2 })
        let same = singleProviderRouter(directory: directory, monitorConnection: false, calibrationIdentifier: identifier)
        XCTAssertEqual(same.profile.samples.count, 1)
        router.updateCalibrationIdentifier(identifier)
        XCTAssertEqual(router.profile.samples.count, 1)
        router.updateCalibrationIdentifier("different model")
        XCTAssertTrue(router.profile.samples.isEmpty)
        let changed = singleProviderRouter(directory: directory, monitorConnection: false, calibrationIdentifier: "different model")
        XCTAssertTrue(changed.profile.samples.isEmpty)
        let data = try String(contentsOf: directory.appendingPathComponent("latency.json"), encoding: .utf8)
        XCTAssertFalse(data.contains(identifier))
        XCTAssertFalse(data.contains("different model"))
    }

    /// Optional storage errors are visible through status while a valid inference result remains usable.
    func testWriteFailureDoesNotLoseInferenceResult() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = singleProviderRouter(directory: directory, monitorConnection: false)
        try Data("not a directory".utf8).write(to: directory)
        let result = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { "valid output" }, onDevice: { "local" })
        XCTAssertEqual(result, "valid output")
        XCTAssertEqual(router.storageStatus, .unavailable)
    }

    /// A reserved-name directory collision must never turn profile cleanup into recursive deletion.
    func testResetRefusesDirectoryCollision() throws {
        for changeMode in [false, true] {
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let collision = directory.appendingPathComponent("latency.json", isDirectory: true)
            try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
            let unrelated = collision.appendingPathComponent("unrelated.txt")
            try Data("preserve".utf8).write(to: unrelated)
            let router = singleProviderRouter(directory: directory, monitorConnection: false)
            XCTAssertEqual(router.storageStatus, .preservedCache)
            if changeMode { XCTAssertThrowsError(try router.setPersistence(.memoryOnly)) }
            else { XCTAssertThrowsError(try router.resetProfile()) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertEqual(router.persistence, .disk)
        }
    }
}
