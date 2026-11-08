import Foundation
import XCTest
import RoutingDemoSupport

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
}
