import Foundation
import XCTest
@testable import RoutingDemoSupport

/// Runs sample-app flows with fixture providers only, without a GUI, Apple inference or cloud quota.
@MainActor
final class DemoModelTests: XCTestCase {
    /// Allocates a sample model whose optional persisted state is isolated from real app support data.
    private func model() -> (DemoModel, URL) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (DemoModel(cacheRoot: root), root)
    }

    /// Fresh sample launches default to local-only simulated requests with disk persistence off.
    func testDefaultLocalStreamingFlow() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(model.mode, .simulated)
        XCTAssertEqual(model.policy, .local)
        XCTAssertEqual(model.preset, .fastest)
        XCTAssertFalse(model.persistCalibration)
        model.start()
        await model.waitUntilFinished()
        XCTAssertEqual(model.status, "Completed on device")
        XCTAssertTrue(model.output.contains("Simulated local reply"))
        XCTAssertEqual(model.attempts.count, 1)
        XCTAssertEqual(model.sampleCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// The sample displays fallback only when the cloud failed before producing output.
    func testAutomaticFallbackFlow() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.policy = .automatic
        model.fault = .beforeOutput
        model.start()
        await model.waitUntilFinished()
        XCTAssertEqual(model.status, "Completed on device")
        XCTAssertEqual(model.attempts.map(\.route), ["Cloud", "On device"])
        XCTAssertNil(model.errorMessage)
    }

    /// Partial errors preserve visible content instead of replacing it with another provider's answer.
    func testPartialFailureFlow() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.policy = .automatic
        model.fault = .afterOutput
        model.start()
        await model.waitUntilFinished()
        XCTAssertEqual(model.status, "Stopped after partial output")
        XCTAssertFalse(model.output.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.attempts.map(\.route), ["Cloud"])
    }

    /// A stalled fixture shows a deadline error and leaves the app ready for a later run.
    func testDeadlineAndCancellationFlows() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.policy = .automatic
        model.fault = .stall
        model.deadlineSeconds = 0.03
        model.start()
        await model.waitUntilFinished()
        XCTAssertEqual(model.status, "Request failed")
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.attempts.map(\.outcome), ["timedOut"])
        model.resetProfile()
        model.deadlineSeconds = 5
        model.fault = .none
        model.start()
        await Task.yield()
        model.cancel()
        XCTAssertEqual(model.status, "Cancelled")
        model.policy = .local
        model.start()
        await model.waitUntilFinished()
        XCTAssertEqual(model.status, "Completed on device")
        XCTAssertFalse(model.isRunning)
    }

    /// Reset and storage controls work without saving prompts or requiring a native model instance.
    func testProfileControlsFlow() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.start()
        await model.waitUntilFinished()
        XCTAssertEqual(model.sampleCount, 1)
        model.setPersistence(true)
        XCTAssertEqual(model.storageLabel, "Saved")
        model.resetProfile()
        XCTAssertEqual(model.sampleCount, 0)
        model.setPersistence(false)
        XCTAssertEqual(model.storageLabel, "In memory")
        XCTAssertNil(model.errorMessage)
    }

    /// Reopening the app retains explicit disk opt-in and learns from the saved profile immediately.
    func testWarmReopenRetainsSavedCalibration() async {
        let (first, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        first.start()
        await first.waitUntilFinished()
        first.setPersistence(true)
        XCTAssertEqual(first.sampleCount, 1)
        let reopened = DemoModel(cacheRoot: root)
        XCTAssertTrue(reopened.persistCalibration)
        reopened.start()
        await reopened.waitUntilFinished()
        XCTAssertEqual(reopened.sampleCount, 2)
        XCTAssertEqual(reopened.storageLabel, "Saved")
        reopened.setPersistence(false)
        XCTAssertFalse(DemoModel(cacheRoot: root).persistCalibration)
    }

    /// Storage remains opt-in for each mode across switches and launches; disabling one preserves the other.
    func testStorageChoicesStayWithTheirModes() {
        let (first, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        first.setPersistence(true)
        first.mode = .apple
        XCTAssertFalse(first.persistCalibration)
        XCTAssertEqual(first.storageLabel, "In memory")
        first.setPersistence(true)
        XCTAssertNil(first.errorMessage)
        first.mode = .simulated
        first.setPersistence(false)
        let reopened = DemoModel(cacheRoot: root)
        XCTAssertFalse(reopened.persistCalibration)
        reopened.mode = .apple
        XCTAssertTrue(reopened.persistCalibration)
        XCTAssertEqual(reopened.storageLabel, "Saved")
        reopened.setPersistence(false)
        reopened.mode = .simulated
        XCTAssertFalse(reopened.persistCalibration)
    }

    /// The old global Boolean cannot identify which provider was allowed to persist data.
    func testLegacyGlobalOptInDoesNotEnableDiskForEitherMode() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"enabled":true}"#.utf8).write(to: root.appendingPathComponent("storage-preference.json"))
        let reopened = DemoModel(cacheRoot: root)
        XCTAssertFalse(reopened.persistCalibration)
        reopened.mode = .apple
        XCTAssertFalse(reopened.persistCalibration)
        XCTAssertEqual(reopened.storageLabel, "In memory")
    }

    /// Seeds qualified simulated local timings, then leaves a cloud probe stalled after the local answer returns.
    private func finishForegroundWithRunningProbe(_ model: DemoModel) async {
        for _ in 0..<3 {
            model.start()
            await model.waitUntilFinished()
        }
        model.policy = .automatic
        model.fault = .stall
        model.start()
        await model.waitUntilFinished()
        XCTAssertEqual(model.status, "Completed on device")
        XCTAssertTrue(model.activeRouter.isCalibrating)
    }

    /// Changing a preset cancels the old background probe and prevents late work overwriting the new owner's file.
    func testReconfigurationRetiresDiskOwnerAfterForegroundCompletion() async throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setPersistence(true)
        await finishForegroundWithRunningProbe(model)
        let oldRouter = model.activeRouter
        model.preset = .balanced
        XCTAssertFalse(oldRouter === model.activeRouter)
        await oldRouter.waitForCalibration()
        XCTAssertEqual(oldRouter.lastCalibrationAttempt?.outcome, .cancelled)
        XCTAssertEqual(oldRouter.storageStatus, .memoryOnly)
        let file = root.appendingPathComponent("simulated/latency.json")
        let current = try Data(contentsOf: file)
        _ = try await oldRouter.measure(model: .onDevice, inputTokens: 10, snapshot: oldRouter.snapshot()) { 1 }
        XCTAssertEqual(try Data(contentsOf: file), current)
    }

    /// A lone window can stop optional generation even after the main request has already completed.
    func testLastWindowCancelsPostResponseCalibration() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = UUID()
        model.windowAppeared(window)
        await finishForegroundWithRunningProbe(model)
        model.windowDisappeared(window)
        await model.activeRouter.waitForCalibration()
        XCTAssertEqual(model.activeRouter.lastCalibrationAttempt?.outcome, .cancelled)
        XCTAssertEqual(model.status, "Completed on device")
    }

    /// Closing one of two windows never interrupts a request another window is displaying.
    func testWindowCancellationIsLimitedToLastVisibleWindow() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID(), second = UUID()
        model.windowAppeared(first)
        model.windowAppeared(second)
        model.start()
        model.windowDisappeared(first)
        model.windowDisappeared(first)
        XCTAssertTrue(model.isRunning)
        await model.waitUntilFinished()
        XCTAssertEqual(model.status, "Completed on device")
        model.start()
        model.windowDisappeared(second)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.status, "Cancelled")
    }
}
