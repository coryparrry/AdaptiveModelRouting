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

        /// Records full-prompt preflight inputs without contacting a tokenizer service.
        func inputTokens(prompt: String, instructions: String?, schema: GenerationSchema?) async throws -> Int {
            tokenCalls += 1
            sawSchema = schema != nil
            self.instructions = instructions
            if let tokenError { throw tokenError }
            return tokens
        }

        /// Records plain-text execution and optionally injects a cloud-specific error.
        func text(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions) async throws -> String {
            routes.append(route)
            prompts.append(prompt)
            self.instructions = instructions
            limits.append(options.maximumResponseTokens)
            if route == .cloud, let cloudError { throw cloudError }
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
}
