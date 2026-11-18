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
