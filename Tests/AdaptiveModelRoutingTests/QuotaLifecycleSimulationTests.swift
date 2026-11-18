import Foundation
import FoundationModels
import XCTest
@testable import AdaptiveModelRouting

/// Replays limited-account lifecycles through real adapter code with entirely synthetic provider operations.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class QuotaLifecycleSimulationTests: XCTestCase {
    /// Uses the production schema/partial-decoding path without invoking Apple model services.
    @Generable
    struct Summary { var text: String }

    /// Supplies independent quota signals and runtime provider failures for all four adapter APIs.
    private final class Backend: FoundationModelsBackend {
        var availability = RoutingAvailability(cloudQuota: .available)
        var localContextCapacity = 8_192
        var error: (any Error)?
        var localError: (any Error)?
        var beforeCloudError: (() -> Void)?
        var routes: [InferenceRoute] = []

        /// Counts tokenization deterministically without using a model service.
        func inputTokens(prompt: String, instructions: String?, schema: GenerationSchema?) async throws -> Int { 100 }

        /// Records a synthetic generation and optionally throws an authentic Apple error value.
        func text(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions) async throws -> String {
            routes.append(route)
            if route == .cloud, let error { beforeCloudError?(); throw error }
            if route == .onDevice, let localError { throw localError }
            return "synthetic"
        }

        /// Decodes typed output while exercising the same failure boundary as plain text.
        func structured<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
            options: GenerationOptions, generating: Content.Type) async throws -> Content {
            _ = try await text(route: route, prompt: prompt, instructions: instructions, options: options)
            return try Content(GeneratedContent(json: "{\"text\":\"synthetic\"}"))
        }
    }

    /// Exercises text, typed generation, text streaming and typed streaming with identical defaults.
    private func invoke(_ adapter: FoundationModelsRouter, format: Int, policy: RoutingPolicy = .automatic) async throws -> InferenceRoute? {
        switch format {
        case 0: return try await adapter.respondDetailed(to: "synthetic", policy: policy).route
        case 1: return try await adapter.respondDetailed(to: "synthetic", generating: Summary.self, policy: policy).route
        default:
            var completed = false
            var route: InferenceRoute?
            if format == 2 {
                for try await event in adapter.stream(to: "synthetic", policy: policy) {
                    if case .completed(let result) = event { completed = true; route = result.route }
                }
            } else {
                for try await event in adapter.stream(to: "synthetic", generating: Summary.self, policy: policy) {
                    if case .completed(let result) = event { completed = true; route = result.route }
                }
            }
            XCTAssertTrue(completed)
            return route
        }
    }

    /// Reopens a synthetic cache using the default configuration and production adapter identity handling.
    private func adapter(directory: URL, backend: Backend) -> FoundationModelsRouter {
        FoundationModelsRouter(router: AdaptiveRouter(directory: directory, system: "quota-lifecycle-simulation",
            monitorConnection: false), options: .init(), backend: backend)
    }

    /// Advances only synthetic fixture timestamps, preserving real default intervals without wall-clock waits.
    private func advanceFixture(_ directory: URL, seconds: TimeInterval) throws {
        let file = directory.appendingPathComponent("latency.json")
        var cache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var profile = try XCTUnwrap(cache["profile"] as? [String: Any])
        for field in ["samples", "failures"] {
            var rows = profile[field] as? [[String: Any]] ?? []
            for index in rows.indices {
                for key in ["date", "retryAfter"] {
                    if let value = rows[index][key] as? Double { rows[index][key] = value - seconds }
                }
            }
            profile[field] = rows
        }
        cache["profile"] = profile
        for key in ["lastCloudUse", "lastLocalLearning", "cloudRetryAfter"] {
            if let value = cache[key] as? Double { cache[key] = value - seconds }
        }
        try JSONSerialization.data(withJSONObject: cache).write(to: file, options: .atomic)
    }

    /// Warnings and exhausted quota forbid all cloud calls until an available signal returns.
    func testWarningExhaustionAndRecoveryAcrossAllFormats() async throws {
        for format in 0..<4 {
            let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let backend = Backend()
            let adapter = adapter(directory: directory, backend: backend)
            for quota in [CloudQuotaStatus.approachingLimit, .exhausted] {
                backend.availability = .init(cloudQuota: quota)
                for _ in 0..<32 {
                    let route = try await invoke(adapter, format: format)
                    XCTAssertEqual(route, .onDevice)
                }
            }
            XCTAssertFalse(backend.routes.contains(.cloud))
            XCTAssertTrue(adapter.router.profile.failures.isEmpty)
            backend.availability = .init(cloudQuota: .available)
            // The restored signal may select a local answer with one due cloud calibration.
            _ = try await invoke(adapter, format: format)
            await adapter.waitForCalibration()
            XCTAssertEqual(backend.routes.filter { $0 == .cloud }.count, 1)
            XCTAssertEqual(adapter.router.profile.samples.filter { $0.model == .cloud }.count, 1)
        }
    }

    /// Runtime failures fall back once, remain quiet across many requests, and recover after paced replay.
    func testRuntimeFailureBackoffAndRecoveryAcrossAllFormats() async throws {
        let errors: [any Error] = [
            PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(debugDescription: "synthetic")),
            LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "synthetic")),
            PrivateCloudComputeLanguageModel.Error.serviceUnavailable(.init(debugDescription: "synthetic")),
            PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "synthetic"))
        ]
        for format in 0..<4 {
            for error in errors {
                let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let backend = Backend()
                backend.error = error
                let first = adapter(directory: directory, backend: backend)
                let route = try await invoke(first, format: format)
                XCTAssertEqual(route, .onDevice)
                await first.waitForCalibration()
                for _ in 0..<32 { _ = try await invoke(first, format: format) }
                XCTAssertEqual(backend.routes.filter { $0 == .cloud }.count, 1)
                XCTAssertTrue(first.router.profile.samples.allSatisfy { $0.model == .onDevice })
                XCTAssertEqual(first.router.profile.failures.filter { $0.model == .cloud }.count, 1)
                try advanceFixture(directory, seconds: 601)
                backend.error = nil
                let recovered = adapter(directory: directory, backend: backend)
                XCTAssertFalse(recovered.router.profile.samples.isEmpty, "Relaunch must retain local evidence")
                _ = try await invoke(recovered, format: format)
                await recovered.waitForCalibration()
                XCTAssertEqual(backend.routes.filter { $0 == .cloud }.count, 2)
                XCTAssertEqual(recovered.router.profile.samples.filter { $0.model == .cloud }.count, 1)
            }
        }
    }

    /// A provider's quota or rate-limit reset must outlive the normal cooldown across all four APIs.
    func testLongRateLimitResetPreventsPrematurePCCProbe() async throws {
        for format in 0..<4 {
            let resetDate = Date.now.addingTimeInterval(3_600)
            let errors: [any Error] = [
                LanguageModelError.rateLimited(.init(resetDate: resetDate, debugDescription: "synthetic")),
                PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(resetDate: resetDate, debugDescription: "synthetic"))
            ]
            for error in errors {
                let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let backend = Backend()
                backend.error = error
                let first = adapter(directory: directory, backend: backend)
                _ = try await invoke(first, format: format)
                await first.waitForCalibration()
                for _ in 0..<3 { _ = try await invoke(first, format: format) }
                try advanceFixture(directory, seconds: 601)
                backend.error = nil
                let waiting = adapter(directory: directory, backend: backend)
                _ = try await invoke(waiting, format: format)
                await waiting.waitForCalibration()
                XCTAssertEqual(backend.routes.filter { $0 == .cloud }.count, 1,
                    "No cloud call before the advertised reset date, format=\(format)")
                try advanceFixture(directory, seconds: 3_001)
                let recovered = adapter(directory: directory, backend: backend)
                _ = try await invoke(recovered, format: format)
                await recovered.waitForCalibration()
                XCTAssertEqual(backend.routes.filter { $0 == .cloud }.count, 2)
            }
        }
    }

    /// Route/identity resets, explicit cloud requests and local failure cannot bypass a known provider deadline.
    func testProviderDeadlineSurvivesResetsAndBlocksFallback() async throws {
        for format in 0..<4 {
            let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let backend = Backend()
            backend.error = LanguageModelError.rateLimited(.init(resetDate: .now.addingTimeInterval(3_600),
                debugDescription: "synthetic"))
            let first = adapter(directory: directory, backend: backend)
            _ = try await invoke(first, format: format)
            await first.waitForCalibration()
            backend.error = nil
            first.router.updateConnection(.init(kind: .cellular, expensive: true))
            first.router.updateCalibrationIdentifier("different synthetic workload")
            try first.router.resetProfile()
            let reopened = adapter(directory: directory, backend: backend)
            let required = try await invoke(reopened, format: format, policy: .cloudRequired)
            XCTAssertNil(required)
            backend.availability = .init(onDevice: false, cloudQuota: .available)
            let unavailable = try await invoke(reopened, format: format)
            XCTAssertNil(unavailable)
            backend.availability = .init(cloudQuota: .available)
            backend.localError = LanguageModelError.timeout(.init(debugDescription: "synthetic local failure"))
            do {
                _ = try await invoke(reopened, format: format)
                XCTFail("A blocked cloud fallback must preserve the local provider failure.")
            } catch LanguageModelError.timeout {}
            await reopened.waitForCalibration()
            XCTAssertEqual(backend.routes.filter { $0 == .cloud }.count, 1)
        }
    }
    /// Provider deadlines remain valid after stale timing generations and a caller's denied fallback.
    func testInflightResetHintSurvivesNetworkIdentityAndFallbackRejection() async throws {
        for format in 0..<4 {
            for boundary in ["network", "identity", "fallback denied"] {
                let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let backend = Backend()
                let core = AdaptiveRouter(directory: directory, system: "quota-lifecycle-simulation", monitorConnection: false)
                let adapter = FoundationModelsRouter(router: core, options: .init(), backend: backend,
                    shouldFallback: { _, error in boundary != "fallback denied" && FoundationModelsRouter.isRetryable(error) })
                backend.error = LanguageModelError.rateLimited(.init(resetDate: .now.addingTimeInterval(3_600),
                    debugDescription: "synthetic late provider error"))
                backend.beforeCloudError = {
                    if boundary == "network" { core.updateConnection(.init(kind: .cellular, expensive: true)) }
                    if boundary == "identity" { core.updateCalibrationIdentifier("new synthetic identity") }
                }
                do {
                    _ = try await invoke(adapter, format: format, policy: .cloudRequired)
                    XCTFail("The injected cloud failure must remain observable")
                } catch is LanguageModelError {}
                await adapter.waitForCalibration()
                backend.error = nil
                backend.beforeCloudError = nil
                let next = try await invoke(adapter, format: format, policy: .cloudRequired)
                XCTAssertNil(next, boundary)
                XCTAssertEqual(backend.routes.filter { $0 == .cloud }.count, 1, "\(boundary), format=\(format)")
            }
        }
    }

    /// A second request must recheck a deadline learned while its local provider was suspended.
    func testConcurrentThrottleBlocksAlreadyPreparedCloudFallback() async throws {
        let profiles = try CostProfiles()
        defer { profiles.cleanup() }
        let router = try profiles.router(.init(policy: .automatic, paired: true, training: .localFaster,
            localReady: true, cloudReady: true, offline: false, capacity: 8_192, cloud: .success, local: .success))
        let cloudGate = ControlledRoutingProvider()
        let localGate = ControlledRoutingProvider()
        defer { cloudGate.release(); localGate.release(); router.cancelCalibration() }
        var lateCloudCalls = 0
        let failingCloud = Task {
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192, policy: .cloudRequired,
                workload: profiles.workload, shouldFallback: { _, error in FoundationModelsRouter.isRetryable(error) },
                cloud: { () async throws -> String? in
                    _ = await cloudGate.call()
                    throw LanguageModelError.rateLimited(.init(resetDate: .now.addingTimeInterval(3_600), debugDescription: "synthetic"))
                }, onDevice: { "forbidden" })
        }
        await cloudGate.started.wait()
        let waitingLocal = Task {
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                workload: profiles.workload, shouldFallback: { _, error in FoundationModelsRouter.isRetryable(error) },
                cloud: { lateCloudCalls += 1; return "must not dispatch" }, onDevice: { () async throws -> String in
                    _ = await localGate.call()
                    throw LanguageModelError.timeout(.init(debugDescription: "synthetic"))
                })
        }
        await localGate.started.wait()
        cloudGate.release()
        do { _ = try await failingCloud.value; XCTFail("Expected synthetic provider throttle") }
        catch is LanguageModelError {}
        localGate.release()
        do {
            _ = try await waitingLocal.value
            XCTFail("The original local timeout must survive the new cloud throttle.")
        } catch LanguageModelError.timeout {}
        XCTAssertEqual(lateCloudCalls, 0)
    }

}
