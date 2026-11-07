import Foundation
import FoundationModels
import AdaptiveModelRouting
import CryptoKit

/// App-facing failures when no permitted result exists or the output budget is invalid.
@available(iOS 27.0, macOS 27.0, *)
public enum FoundationModelsAdapterError: Error {
    case noResult(RoutingResultStatus)
    case invalidResponseLimit
}

/// Ready-to-use Apple local/PCC routing with fresh sessions, native tokenization and typed output.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
public final class FoundationModelsRouter {
    public let router: AdaptiveRouter
    private let backend: any FoundationModelsBackend
    private let instructions: String?
    private let options: GenerationOptions
    private let shouldFallback: (InferenceRoute, any Error) -> Bool

    /// Creates one named workload; PCC access still requires the consuming app's managed entitlement.
    /// Names are encoded as a single cache component so slashes and dot segments cannot escape the root.
    public convenience init(
        workload: String = "default", instructions: String? = nil,
        configuration: RoutingConfiguration = .balanced,
        options: GenerationOptions = .init(maximumResponseTokens: 512),
        cacheRoot: URL = URL.applicationSupportDirectory.appendingPathComponent("AdaptiveFoundationModels"),
        localModel: SystemLanguageModel = .default,
        cloudModel: PrivateCloudComputeLanguageModel = .init(),
        shouldFallback: @escaping (InferenceRoute, any Error) -> Bool = { _, error in isRetryable(error) }
    ) {
        let component = "workload-" + SHA256.hash(data: Data(workload.utf8)).map { String(format: "%02x", $0) }.joined()
        let router = AdaptiveRouter(directory: cacheRoot.appendingPathComponent(component), configuration: configuration)
        self.init(router: router, instructions: instructions, options: options,
            backend: AppleFoundationModelsBackend(local: localModel, cloud: cloudModel), shouldFallback: shouldFallback)
    }

    /// Injects SDK operations for deterministic tests without exposing a second public provider abstraction.
    init(router: AdaptiveRouter, instructions: String? = nil, options: GenerationOptions,
        backend: any FoundationModelsBackend,
        shouldFallback: @escaping (InferenceRoute, any Error) -> Bool = { _, error in isRetryable(error) }) {
        self.router = router
        self.instructions = instructions
        self.options = options
        self.backend = backend
        self.shouldFallback = shouldFallback
    }

    /// Maps explicit Apple transport, quota and service failures while preserving refusals and invalid requests.
    public static func isRetryable(_ error: any Error) -> Bool {
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .networkFailure, .quotaLimitReached, .serviceUnavailable: return true
            @unknown default: return false
            }
        }
        if let error = error as? LanguageModelError {
            switch error {
            case .timeout, .rateLimited: return true
            default: return false
            }
        }
        return InferenceExecutor.isRetryable(error)
    }

    /// Generates plain text or throws a typed no-result error; provider errors remain unchanged.
    public func respond(to prompt: String, policy: RoutingPolicy = .automatic) async throws -> String {
        let result = try await respondDetailed(to: prompt, policy: policy)
        guard let value = result.value else { throw FoundationModelsAdapterError.noResult(result.status) }
        return value
    }

    /// Generates a concrete Generable type with schema-aware local context accounting.
    public func respond<Content: Generable>(to prompt: String, generating: Content.Type,
        policy: RoutingPolicy = .automatic) async throws -> Content {
        let result = try await respondDetailed(to: prompt, generating: generating, policy: policy)
        guard let value = result.value else { throw FoundationModelsAdapterError.noResult(result.status) }
        return value
    }

    /// Returns text with selection reason, actual route and content-free attempt timing.
    public func respondDetailed(to prompt: String, policy: RoutingPolicy = .automatic,
        onAttempt: ((RoutingAttempt) -> Void)? = nil) async throws -> RoutingResult<String> {
        try await execute(prompt: prompt, schema: nil, policy: policy, onAttempt: onAttempt) { route, options in
            try await self.backend.text(route: route, prompt: prompt, instructions: self.instructions, options: options)
        }
    }

    /// Returns typed output with diagnostics, tokenizing the same schema supplied to generation.
    public func respondDetailed<Content: Generable>(to prompt: String, generating: Content.Type,
        policy: RoutingPolicy = .automatic, onAttempt: ((RoutingAttempt) -> Void)? = nil) async throws -> RoutingResult<Content> {
        try await execute(prompt: prompt, schema: Content.generationSchema, policy: policy, onAttempt: onAttempt) { route, options in
            try await self.backend.structured(route: route, prompt: prompt, instructions: self.instructions,
                options: options, generating: generating)
        }
    }

    /// Resolves budgets and readiness once; skips local tokenization when local inference is unavailable.
    private func execute<Value>(prompt: String, schema: GenerationSchema?, policy: RoutingPolicy,
        onAttempt: ((RoutingAttempt) -> Void)?, generate: (InferenceRoute, GenerationOptions) async throws -> Value
    ) async throws -> RoutingResult<Value> {
        try Task.checkCancellation()
        var options = options
        let limit = options.maximumResponseTokens ?? router.configuration.localResponseReserve
        guard limit > 0 else { throw FoundationModelsAdapterError.invalidResponseLimit }
        options.maximumResponseTokens = limit
        var availability = backend.availability
        let useLocal = availability.onDevice && policy != .cloudRequired
        var tokens = 0
        if useLocal {
            do { tokens = try await backend.inputTokens(prompt: prompt, instructions: instructions, schema: schema) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let retry = availability.cloud && shouldFallback(.onDevice, error)
                try Task.checkCancellation()
                guard retry else { throw error }
                availability = .init(onDevice: false, cloud: availability.cloud)
            }
        }
        try Task.checkCancellation()
        return try await router.respondDetailed(inputTokens: tokens,
            localContextCapacity: availability.onDevice && policy != .cloudRequired ? backend.localContextCapacity : 0,
            policy: policy, workload: .init(expectedOutputTokens: limit), availability: availability,
            shouldFallback: shouldFallback, onAttempt: onAttempt,
            cloud: { try await generate(.cloud, options) }, onDevice: { try await generate(.onDevice, options) })
    }
}
