import Foundation
import FoundationModels
import Observation
import XCTest
@testable import RoutingDemoSupport

/// Runs sample-app flows with fixture providers only, without a GUI, Apple inference or cloud quota.
@MainActor
final class DemoModelTests: XCTestCase {
    /// Allocates a sample model whose optional persisted state is isolated from real app support data.
    private func model() -> (DemoModel, URL) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (fixtureModel(cacheRoot: root), root)
    }

    /// Supplies a separate simulated owner for Apple mode, including when reopening saved state.
    private func fixtureModel(cacheRoot: URL) -> DemoModel {
        DemoModel(cacheRoot: cacheRoot, makeAppleOwner: DemoRoutingOwner.fixture)
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

    /// Apple mode can complete a fixture request without initializing the Apple model service.
    func testAppleModeUsesInjectedProvider() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.mode = .apple
        model.policy = .cloud
        model.start()
        await model.waitUntilFinished()
        XCTAssertEqual(model.status, "Completed in cloud")
        XCTAssertTrue(model.output.contains("Simulated cloud reply"))
        XCTAssertEqual(model.attempts.map(\.route), ["Cloud"])
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

    /// A provider switch clears the previous request's response and diagnostics, including partial errors.
    func testChangingProvidersClearsDisplayedRequest() async {
        for fault in [DemoFault.none, .afterOutput] {
            let (model, root) = model()
            defer { try? FileManager.default.removeItem(at: root) }
            model.fault = fault
            model.policy = .cloud
            model.start()
            await model.waitUntilFinished()
            XCTAssertFalse(model.output.isEmpty)
            XCTAssertFalse(model.attempts.isEmpty)
            XCTAssertEqual(model.errorMessage != nil, fault == .afterOutput)

            model.mode = .apple
            XCTAssertTrue(model.output.isEmpty)
            XCTAssertTrue(model.attempts.isEmpty)
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.status, "Ready")
            XCTAssertEqual(model.selectionReason, "No request yet")
            XCTAssertEqual(model.sampleCount, 0)
            model.mode = .simulated
            XCTAssertEqual(model.sampleCount, fault == .none ? 1 : 0)
            XCTAssertTrue(model.output.isEmpty)
        }
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
        let reopened = fixtureModel(cacheRoot: root)
        XCTAssertTrue(reopened.persistCalibration)
        reopened.start()
        await reopened.waitUntilFinished()
        XCTAssertEqual(reopened.sampleCount, 2)
        XCTAssertEqual(reopened.storageLabel, "Saved")
        reopened.setPersistence(false)
        XCTAssertFalse(fixtureModel(cacheRoot: root).persistCalibration)
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
        let reopened = fixtureModel(cacheRoot: root)
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
        let reopened = fixtureModel(cacheRoot: root)
        XCTAssertFalse(reopened.persistCalibration)
        reopened.mode = .apple
        XCTAssertFalse(reopened.persistCalibration)
        XCTAssertEqual(reopened.storageLabel, "In memory")
    }

    /// Verifies a settings change through a cloud-required request after one local sample and a server throttle.
    private func assertEditPreservesInMemoryTimingsAndCloudThrottle(_ edit: (DemoModel) -> Void) async throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.start()
        await model.waitUntilFinished()
        let router = model.activeRouter
        do {
            let _: String? = try await router.respond(inputTokens: 10, localContextCapacity: 8_192, policy: .cloudRequired,
                cloud: { throw LanguageModelError.rateLimited(.init(resetDate: .now.addingTimeInterval(3_600), debugDescription: "fixture")) },
                onDevice: { XCTFail("Cloud required"); return "unexpected" })
            XCTFail("Expected the provider throttle")
        } catch LanguageModelError.rateLimited {}

        edit(model)
        XCTAssertTrue(model.activeRouter === router)
        XCTAssertEqual(model.activeRouter.profile.samples.count, 1)
        XCTAssertEqual(model.sampleCount, 1)
        model.policy = .cloud
        model.start()
        await model.waitUntilFinished()
        XCTAssertEqual(model.status, "No permitted model is available")
        XCTAssertTrue(model.attempts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// Editing the next request's deadline keeps learned timings and the active provider-wide retry date.
    func testDeadlineEditPreservesInMemoryTimingsAndCloudThrottle() async throws {
        try await assertEditPreservesInMemoryTimingsAndCloudThrottle { $0.deadlineSeconds = 1 }
    }

    /// Each provider mode keeps its own timings and server retry date across a round trip.
    func testModeRoundTripPreservesInMemoryTimingsAndCloudThrottle() async throws {
        try await assertEditPreservesInMemoryTimingsAndCloudThrottle { model in
            model.mode = .apple
            XCTAssertEqual(model.sampleCount, 0)
            let apple = model.activeRouter
            model.preset = .quality
            model.mode = .simulated
            XCTAssertEqual(model.activeRouter.configuration.minimumSamples, DemoPreset.quality.value.minimumSamples)
            model.mode = .apple
            XCTAssertTrue(model.activeRouter === apple)
            model.mode = .simulated
        }
    }

    /// Switching presets applies the selected thresholds while retaining the same history and server throttle.
    func testPresetChangePreservesInMemoryTimingsAndCloudThrottle() async throws {
        try await assertEditPreservesInMemoryTimingsAndCloudThrottle { model in
            model.preset = .quality
            let configuration = model.activeRouter.configuration
            let preset = DemoPreset.quality.value
            XCTAssertEqual(configuration.minimumLocalSavingSeconds, preset.minimumLocalSavingSeconds)
            XCTAssertEqual(configuration.minimumLocalSavingFraction, preset.minimumLocalSavingFraction)
            XCTAssertEqual(configuration.minimumSamples, preset.minimumSamples)
            XCTAssertEqual(configuration.predictionSampleLimit, preset.predictionSampleLimit)
            XCTAssertEqual(configuration.variabilityAllowance, preset.variabilityAllowance)
        }
    }

    /// Seeds qualified simulated local timings, then returns while the slower cloud probe is active.
    private func finishForegroundWithRunningProbe(_ model: DemoModel, fault: DemoFault = .stall) async {
        for _ in 0..<3 {
            model.start()
            await model.waitUntilFinished()
        }
        model.policy = .automatic
        model.fault = fault
        model.start()
        await model.waitUntilFinished()
        XCTAssertEqual(model.status, "Completed on device")
        XCTAssertTrue(model.activeRouter.isCalibrating)
    }

    /// The same action as the view's Cancel button can stop a probe after the visible answer completes.
    func testCancelRemainsAvailableForPostResponseCalibration() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        await finishForegroundWithRunningProbe(model)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.canCancel)
        model.cancel()
        XCTAssertFalse(model.canCancel)
        await model.activeRouter.waitForCalibration()
        XCTAssertEqual(model.activeRouter.lastCalibrationAttempt?.outcome, .cancelled)
        XCTAssertEqual(model.status, "Completed on device")
    }

    /// A preset edit cancels optional work from the previous selection while preserving its admitted samples.
    func testPresetChangeCancelsPostResponseCalibration() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        await finishForegroundWithRunningProbe(model)
        let samples = model.sampleCount
        model.preset = .balanced
        await model.activeRouter.waitForCalibration()
        XCTAssertFalse(model.canCancel)
        XCTAssertEqual(model.activeRouter.lastCalibrationAttempt?.outcome, .cancelled)
        XCTAssertEqual(model.sampleCount, samples)
    }

    /// Completing a healthy late probe updates observed controls and displays the extra timing automatically.
    func testCompletedCalibrationRefreshesDisplayedTimingCount() async {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        await finishForegroundWithRunningProbe(model, fault: .none)
        let foregroundSamples = model.sampleCount
        let changed = XCTestExpectation(description: "Cancel availability changed")
        let canCancel = withObservationTracking { model.canCancel } onChange: { changed.fulfill() }
        XCTAssertTrue(canCancel)
        let outcome = await XCTWaiter.fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(outcome, .completed)
        XCTAssertFalse(model.canCancel)
        XCTAssertEqual(model.sampleCount, foregroundSamples + 1)
        XCTAssertEqual(model.activeRouter.lastCalibrationAttempt?.outcome, .succeeded)
    }

    /// Switching modes cancels the old probe and pauses writes until the disk-backed mode returns.
    func testModeChangePausesAndResumesDiskOwnerAfterForegroundCompletion() async throws {
        let (model, root) = model()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setPersistence(true)
        await finishForegroundWithRunningProbe(model)
        let oldRouter = model.activeRouter
        model.mode = .apple
        XCTAssertFalse(oldRouter === model.activeRouter)
        await oldRouter.waitForCalibration()
        XCTAssertEqual(oldRouter.lastCalibrationAttempt?.outcome, .cancelled)
        XCTAssertEqual(oldRouter.storageStatus, .memoryOnly)
        let file = root.appendingPathComponent("simulated/latency.json")
        let current = try Data(contentsOf: file)
        _ = try await oldRouter.measure(model: .onDevice, inputTokens: 10, snapshot: oldRouter.snapshot()) { 1 }
        XCTAssertEqual(try Data(contentsOf: file), current)
        model.mode = .simulated
        XCTAssertTrue(model.activeRouter === oldRouter)
        XCTAssertEqual(model.activeRouter.storageStatus, .persisted)
        XCTAssertNotEqual(try Data(contentsOf: file), current)
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
