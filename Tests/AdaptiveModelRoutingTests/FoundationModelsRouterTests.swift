import Foundation
import FoundationModels
import XCTest
@testable import AdaptiveModelRouting

/// Verifies the Apple adapter without invoking model services, consuming quota or requiring an entitlement.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class FoundationModelsRouterTests: XCTestCase {
    /// Supplies typed generated output through the same macro contract as an app.
    @Generable
    struct Summary { var text: String }

    /// Records SDK boundaries and returns deterministic text or decoded structured content.
    private final class Backend: FoundationModelsBackend {
        var availability = RoutingAvailability()
        var localContextCapacity = 8_192
        var tokens = 100
        var tokenCalls = 0
        var sawSchema = false
        var instructions: String?
        var prompts: [String] = []
        var routes: [InferenceRoute] = []
        var limits: [Int?] = []
        var cloudError: (any Error)?
        var tokenError: (any Error)?
        var localError: (any Error)?
        var tokenProvider: ControlledRoutingProvider?
        var inspectedPolicies: [RoutingPolicy] = []

        /// Records which hard policy the adapter applies before inspecting provider readiness.
        func availability(for policy: RoutingPolicy) -> RoutingAvailability {
            inspectedPolicies.append(policy)
            return .init(onDevice: policy != .cloudRequired && availability.onDevice,
                cloud: policy != .localOnly && availability.cloud)
        }

        /// Records full-prompt preflight inputs without contacting a tokenizer service.
        func inputTokens(prompt: String, instructions: String?, schema: GenerationSchema?) async throws -> Int {
            tokenCalls += 1
            sawSchema = schema != nil
            self.instructions = instructions
            if let tokenError { throw tokenError }
            if let tokenProvider { _ = await tokenProvider.call() }
            return tokens
        }

        /// Records plain-text execution and optionally injects a cloud-specific error.
        func text(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions) async throws -> String {
            routes.append(route)
            prompts.append(prompt)
            self.instructions = instructions
            limits.append(options.maximumResponseTokens)
            if route == .cloud, let cloudError { throw cloudError }
            if route == .onDevice, let localError { throw localError }
            return route == .cloud ? "cloud" : "local"
        }

        /// Converts deterministic JSON through the real Generable decoding interface.
        func structured<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
            options: GenerationOptions, generating: Content.Type) async throws -> Content {
            _ = try await text(route: route, prompt: prompt, instructions: instructions, options: options)
            return try Content(GeneratedContent(json: "{\"text\":\"typed output\"}"))
        }
    }

    /// Creates isolated routing storage with caller-controlled SDK operations and generation settings.
    private func fixture(options: GenerationOptions = .init(maximumResponseTokens: 512),
        configuration: RoutingConfiguration = .balanced) -> (FoundationModelsRouter, Backend, URL) {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let core = AdaptiveRouter(directory: directory, monitorConnection: false, configuration: configuration)
        let backend = Backend()
        return (FoundationModelsRouter(router: core, instructions: "Summarize clearly", options: options, backend: backend), backend, directory)
    }

    /// The simple string API handles provider execution, token accounting, instructions and response limits.
    func testTextConvenienceAndDiagnostics() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await router.respondDetailed(to: "Summarize this")
        XCTAssertEqual(result.value, "cloud")
        XCTAssertEqual(result.route, .cloud)
        XCTAssertEqual(result.decision.reason, .insufficientEvidence)
        XCTAssertEqual(backend.tokenCalls, 1)
        XCTAssertEqual(backend.instructions, "Summarize clearly")
        XCTAssertEqual(backend.prompts, ["Summarize this"])
        XCTAssertEqual(backend.limits, [512])
        XCTAssertEqual(router.router.profile.samples.first?.tokens, 100)
        XCTAssertEqual(router.router.profile.samples.first?.workload?.expectedOutputTokens, 512)
        let text = try await router.respond(to: "Another summary")
        XCTAssertEqual(text, "cloud")
    }

    /// Structured responses use schema-aware preflight and return the app's concrete generated type.
    func testStructuredOutputUsesSchema() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await router.respond(to: "Summarize", generating: Summary.self)
        XCTAssertEqual(result.text, "typed output")
        XCTAssertTrue(backend.sawSchema)
    }

    /// Known quota exhaustion bypasses cloud without treating local execution as a failed cloud attempt.
    func testUnavailableCloudUsesLocal() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        backend.availability = .init(cloud: false)
        let result = try await router.respondDetailed(to: "Summary")
        XCTAssertEqual(result.value, "local")
        XCTAssertEqual(result.decision.reason, .cloudUnavailable)
        XCTAssertEqual(backend.routes, [.onDevice])
        XCTAssertFalse(result.didFallback)
    }

    /// Cloud-only requests do not depend on a functioning local tokenizer or local model capacity.
    func testCloudRequiredSkipsLocalPreflight() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        backend.tokenError = URLError(.resourceUnavailable)
        let text = try await router.respond(to: "Complex task", policy: .cloudRequired)
        XCTAssertEqual(text, "cloud")
        XCTAssertEqual(backend.tokenCalls, 0)
        XCTAssertEqual(backend.routes, [.cloud])
    }

    /// Cloud-required unavailability yields a typed no-result error without relaxing the quality requirement.
    func testCloudRequiredUnavailableThrowsTypedError() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        backend.availability = .init(cloud: false)
        do {
            _ = try await router.respond(to: "Complex task", policy: .cloudRequired)
            XCTFail("Unavailable required cloud must not run local inference.")
        } catch FoundationModelsAdapterError.noResult(let status) { XCTAssertEqual(status, .unavailable) }
        XCTAssertTrue(backend.routes.isEmpty)
    }

    /// Local unavailability skips local tokenization and does not prevent a usable cloud response.
    func testUnavailableLocalDoesNotBlockCloud() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        backend.availability = .init(onDevice: false)
        let result = try await router.respondDetailed(to: "Summary")
        XCTAssertEqual(result.value, "cloud")
        XCTAssertEqual(result.decision.reason, .localUnavailable)
        XCTAssertEqual(backend.tokenCalls, 0)
    }

    /// The real generation limit protects local capacity instead of using only the smaller default reserve.
    func testResponseLimitPreventsLocalOverflow() async throws {
        let (router, backend, directory) = fixture(options: .init(maximumResponseTokens: 1_000))
        defer { try? FileManager.default.removeItem(at: directory) }
        backend.tokens = 7_500
        backend.availability = .init(cloud: false)
        let result = try await router.respondDetailed(to: "Large input")
        XCTAssertEqual(result.status, .requiresChunking)
        XCTAssertTrue(backend.routes.isEmpty)
    }

    /// An unset output limit becomes the configured reserve, and an invalid explicit limit fails before SDK calls.
    func testMissingAndInvalidResponseLimits() async throws {
        let (router, backend, directory) = fixture(options: .init())
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await router.respond(to: "Summary")
        XCTAssertEqual(backend.limits, [400])
        let (invalid, invalidBackend, otherDirectory) = fixture(options: .init(), configuration: .init(localResponseReserve: 0))
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        do {
            _ = try await invalid.respond(to: "Summary")
            XCTFail("Invalid limits must fail before provider execution.")
        } catch FoundationModelsAdapterError.invalidResponseLimit {}
        XCTAssertEqual(invalidBackend.tokenCalls, 0)
        XCTAssertTrue(invalidBackend.routes.isEmpty)
    }

    /// Apple quota failures trigger the documented fallback and remain visible in attempt diagnostics.
    func testAppleQuotaFailureFallsBackOnce() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        backend.cloudError = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(debugDescription: "quota"))
        let result = try await router.respondDetailed(to: "Summary")
        XCTAssertEqual(result.value, "local")
        XCTAssertEqual(backend.routes, [.cloud, .onDevice])
        XCTAssertEqual(result.attempts.map(\.outcome), [.failed, .succeeded])
        XCTAssertTrue(result.didFallback)
        XCTAssertEqual(router.router.profile.failures.map(\.model), [.cloud])
    }

    /// The Apple mapping permits explicit transport/rate failures and preserves permanent context errors.
    func testAppleErrorClassification() {
        XCTAssertTrue(FoundationModelsRouter.isRetryable(
            PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "network"))))
        XCTAssertTrue(FoundationModelsRouter.isRetryable(
            PrivateCloudComputeLanguageModel.Error.serviceUnavailable(.init(debugDescription: "service"))))
        XCTAssertTrue(FoundationModelsRouter.isRetryable(LanguageModelError.timeout(.init(debugDescription: "timeout"))))
        XCTAssertTrue(FoundationModelsRouter.isRetryable(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "rate"))))
        XCTAssertFalse(FoundationModelsRouter.isRetryable(LanguageModelError.contextSizeExceeded(
            .init(contextSize: 100, tokenCount: 200, debugDescription: "oversized"))))
        XCTAssertFalse(FoundationModelsRouter.isRetryable(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(FoundationModelsRouter.isRetryable(LanguageModelError.guardrailViolation(.init(debugDescription: "guardrail"))))
        XCTAssertFalse(FoundationModelsRouter.isRetryable(LanguageModelError.refusal(.init(explanation: "refused", debugDescription: "refusal"))))
    }

    /// Recoverable local-tokenizer failures can use cloud without mislabelling tokenization as an inference attempt.
    func testRecoverablePreflightFailureCanUseCloud() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        backend.tokenError = URLError(.resourceUnavailable)
        let result = try await router.respondDetailed(to: "Summary")
        XCTAssertEqual(result.value, "cloud")
        XCTAssertEqual(result.decision.reason, .localUnavailable)
        XCTAssertEqual(result.attempts.map(\.route), [.cloud])
        XCTAssertFalse(result.availability.onDevice)
    }

    /// Permanent preflight errors propagate unchanged instead of sending a second provider an invalid request.
    func testPermanentPreflightFailureDoesNotGenerate() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        backend.tokenError = URLError(.badURL)
        do {
            _ = try await router.respond(to: "Summary")
            XCTFail("Permanent preflight errors must propagate.")
        } catch let error as URLError { XCTAssertEqual(error.code, .badURL) }
        XCTAssertTrue(backend.routes.isEmpty)
    }

    /// Cancellation during preflight propagates without making or recording an inference request.
    func testPreflightCancellationDoesNotGenerate() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        backend.tokenError = CancellationError()
        do {
            _ = try await router.respond(to: "Summary")
            XCTFail("Cancellation must propagate.")
        } catch is CancellationError {}
        XCTAssertTrue(backend.routes.isEmpty)
        XCTAssertTrue(router.router.profile.samples.isEmpty)
        XCTAssertTrue(router.router.profile.failures.isEmpty)
    }

    /// Local-only readiness and native execution never inspect or attempt the cloud lane.
    func testLocalOnlyMasksCloudAndPreservesLocalErrors() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await router.respondDetailed(to: "Private summary", policy: .localOnly)
        XCTAssertEqual(result.value, "local")
        XCTAssertEqual(result.decision.reason, .localOnly)
        XCTAssertFalse(result.availability.cloud)
        XCTAssertEqual(backend.inspectedPolicies, [.localOnly])
        backend.localError = URLError(.timedOut)
        do {
            _ = try await router.respond(to: "Private summary", policy: .localOnly)
            XCTFail("A local failure must not authorize cloud.")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertEqual(backend.routes, [.onDevice, .onDevice])
    }

    /// The request deadline starts before token counting rather than only before inference.
    func testDeadlineIncludesPreflight() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ControlledRoutingProvider()
        backend.tokenProvider = provider
        let safety = Task { try? await Task.sleep(for: .seconds(5)); provider.release() }
        defer { safety.cancel(); provider.release() }
        var attempts: [RoutingAttempt] = []
        let task = Task {
            try await router.respondDetailed(to: "Summary", deadline: .after(.milliseconds(200)), onAttempt: { attempts.append($0) })
        }
        await provider.started.wait()
        do { _ = try await task.value; XCTFail("Preflight must share the request deadline.") }
        catch RoutingRequestError.deadlineExceeded {}
        XCTAssertFalse(provider.released)
        XCTAssertTrue(backend.routes.isEmpty)
        XCTAssertTrue(attempts.isEmpty)
        provider.release()
        await provider.finished.wait()
        XCTAssertTrue(router.router.profile.samples.isEmpty)
    }

    /// Text streaming returns metadata and never adds an extra generation request.
    func testTextStreamingUsesOnePermittedProvider() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var result: RoutingResult<String>?
        for try await event in router.stream(to: "Summary", policy: .localOnly) {
            if case .completed(let value) = event { result = value }
        }
        XCTAssertEqual(result?.value, "local")
        XCTAssertEqual(backend.routes, [.onDevice])
        XCTAssertEqual(backend.tokenCalls, 1)
    }

    /// Native partial-field output uses the concrete generated schema and a single model request.
    func testTypedStreamingUsesPartialFields() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var result: RoutingResult<Summary.PartiallyGenerated>?
        for try await event in router.stream(to: "Summary", generating: Summary.self) {
            if case .completed(let value) = event { result = value }
        }
        XCTAssertEqual(result?.value?.text, "typed output")
        XCTAssertTrue(backend.sawSchema)
        XCTAssertEqual(backend.routes, [.cloud])
    }

    /// Instruction, schema, sampling and model-identity changes invalidate calibration automatically.
    func testGenerationIdentityChangesInvalidateCalibration() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<2 { _ = try await router.respond(to: "Summary") }
        XCTAssertEqual(router.router.profile.samples.count, 2)
        let instructions = "PRIVATE-INSTRUCTIONS-DO-NOT-STORE"
        let other = FoundationModelsRouter(router: router.router, instructions: instructions,
            options: .init(maximumResponseTokens: 512), backend: backend)
        _ = try await other.respond(to: "Summary")
        XCTAssertEqual(router.router.profile.samples.count, 1)
        for _ in 0..<2 { _ = try await other.respond(to: "Summary", generating: Summary.self) }
        XCTAssertEqual(router.router.profile.samples.count, 2, "Stable schemas must not reset on each request.")
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 512)
        let changed = FoundationModelsRouter(router: router.router, instructions: instructions, options: options, backend: backend)
        _ = try await changed.respond(to: "Summary", generating: Summary.self)
        XCTAssertEqual(router.router.profile.samples.count, 1)
        let model = FoundationModelsRouter(router: router.router, instructions: instructions, options: options,
            backend: backend, modelIdentifier: "MODEL-VERSION-PRIVATE")
        _ = try await model.respond(to: "Summary", generating: Summary.self)
        XCTAssertEqual(router.router.profile.samples.count, 1)
        let cached = try String(contentsOf: directory.appendingPathComponent("latency.json"), encoding: .utf8)
        XCTAssertFalse(cached.contains(instructions))
        XCTAssertFalse(cached.contains("MODEL-VERSION-PRIVATE"))
    }

    /// Relaunching restores a stable native identity while the next changed schema still resets calibration.
    func testStableIdentitySurvivesRouterRecreation() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<2 { _ = try await router.respond(to: "Summary") }
        let restored = FoundationModelsRouter(
            router: AdaptiveRouter(directory: directory, monitorConnection: false),
            instructions: "Summarize clearly", options: .init(maximumResponseTokens: 512), backend: backend)
        XCTAssertEqual(restored.profile.samples.count, 2)
        _ = try await restored.respond(to: "Another summary")
        XCTAssertEqual(restored.profile.samples.count, 3)
        _ = try await restored.respond(to: "Structured summary", generating: Summary.self)
        XCTAssertEqual(restored.profile.samples.count, 1)
    }

    /// Suspended text preflight cannot accidentally train the structured request's active calibration bucket.
    func testConcurrentPreflightKeepsCalibrationIdentityIsolated() async throws {
        let (router, backend, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ControlledRoutingProvider()
        backend.tokenProvider = provider
        let safety = Task { try? await Task.sleep(for: .seconds(5)); provider.release() }
        defer { safety.cancel(); provider.release() }
        let text = Task { try await router.respond(to: "Text request") }
        await provider.started.wait()
        backend.tokenProvider = nil
        _ = try await router.respond(to: "Structured request", generating: Summary.self)
        XCTAssertEqual(router.router.profile.samples.count, 1)
        let file = directory.appendingPathComponent("latency.json")
        let structuredIdentity = (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["identity"] as? String
        provider.release()
        _ = try await text.value
        XCTAssertEqual(router.router.profile.samples.count, 1)
        let textIdentity = (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["identity"] as? String
        XCTAssertNotEqual(textIdentity, structuredIdentity)
    }
}
