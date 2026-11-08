import Foundation
import FoundationModels
import CryptoKit

/// App-facing failures when no permitted result exists or the output budget is invalid.
@available(iOS 27.0, macOS 27.0, *)
public enum FoundationModelsAdapterError: LocalizedError {
    case noResult(RoutingResultStatus)
    case invalidResponseLimit

    public var errorDescription: String? {
        switch self {
        case .noResult(.requiresChunking): "Split the input into smaller parts before trying again."
        case .noResult: "No permitted model is available for this request."
        case .invalidResponseLimit: "The maximum response length must be positive."
        }
    }
}

/// Ready-to-use Apple local/PCC routing with fresh sessions, native tokenization and typed output.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
public final class FoundationModelsRouter {
    public let router: AdaptiveRouter
    let backend: any FoundationModelsBackend
    let instructions: String?
    private let options: GenerationOptions
    private let modelIdentifier: String
    let shouldFallback: (InferenceRoute, any Error) -> Bool

    /// Exposes current learned timings without requiring the caller to navigate the core router.
    public var profile: PerformanceProfile { router.profile }
    /// Reports whether optional calibration is in memory, saved, unavailable or preserved for recovery.
    public var storageStatus: RoutingStorageStatus { router.storageStatus }

    /// Clears this workload's timings and its owned metadata file when disk storage is enabled.
    public func resetProfile() throws { try router.resetProfile() }

    /// Changes calibration storage and removes the owned file by default when disabling disk persistence.
    public func setPersistence(_ value: RoutingPersistence, clearExistingCache: Bool = true) throws {
        try router.setPersistence(value, clearExistingCache: clearExistingCache)
    }

    /// Creates one named workload; PCC access still requires the consuming app's managed entitlement.
    /// Names are encoded as a single cache component so slashes and dot segments cannot escape the root.
    public convenience init(
        workload: String = "default", instructions: String? = nil,
        configuration: RoutingConfiguration = .balanced,
        options: GenerationOptions = .init(maximumResponseTokens: 512),
        cacheRoot: URL = AdaptiveRouter.defaultCacheDirectory.appendingPathComponent("AppleWorkloads", isDirectory: true),
        localModel: SystemLanguageModel? = nil,
        cloudModel: PrivateCloudComputeLanguageModel? = nil,
        modelIdentifier: String? = nil, persistence: RoutingPersistence = .disk,
        shouldFallback: @escaping (InferenceRoute, any Error) -> Bool = { _, error in isRetryable(error) }
    ) {
        let component = "workload-" + SHA256.hash(data: Data(workload.utf8)).map { String(format: "%02x", $0) }.joined()
        let router = AdaptiveRouter(directory: cacheRoot.appendingPathComponent(component), configuration: configuration, persistence: persistence)
        let identity = modelIdentifier ?? (localModel == nil && cloudModel == nil ? "apple-default-models" : UUID().uuidString)
        self.init(router: router, instructions: instructions, options: options,
            backend: AppleFoundationModelsBackend(local: localModel ?? .default, cloud: cloudModel), modelIdentifier: identity, shouldFallback: shouldFallback)
    }

    /// Injects SDK operations for deterministic tests without exposing a second public provider abstraction.
    init(router: AdaptiveRouter, instructions: String? = nil, options: GenerationOptions,
        backend: any FoundationModelsBackend, modelIdentifier: String = "apple-default-models",
        shouldFallback: @escaping (InferenceRoute, any Error) -> Bool = { _, error in isRetryable(error) }) {
        self.router = router
        self.instructions = instructions
        self.options = options
        self.backend = backend
        self.modelIdentifier = modelIdentifier
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
    public func respond(to prompt: String, policy: RoutingPolicy = .automatic, deadline: RoutingDeadline? = nil) async throws -> String {
        let result = try await respondDetailed(to: prompt, policy: policy, deadline: deadline)
        guard let value = result.value else { throw FoundationModelsAdapterError.noResult(result.status) }
        return value
    }

    /// Generates a concrete Generable type with schema-aware local context accounting.
    public func respond<Content: Generable>(to prompt: String, generating: Content.Type,
        policy: RoutingPolicy = .automatic, deadline: RoutingDeadline? = nil) async throws -> Content {
        let result = try await respondDetailed(to: prompt, generating: generating, policy: policy, deadline: deadline)
        guard let value = result.value else { throw FoundationModelsAdapterError.noResult(result.status) }
        return value
    }

    /// Returns text with selection reason, actual route and content-free attempt timing.
    public func respondDetailed(to prompt: String, policy: RoutingPolicy = .automatic, deadline: RoutingDeadline? = nil,
        onAttempt: ((RoutingAttempt) -> Void)? = nil) async throws -> RoutingResult<String> {
        try await execute(prompt: prompt, schema: nil, policy: policy, deadline: deadline, onAttempt: onAttempt) { route, options in
            try await self.backend.text(route: route, prompt: prompt, instructions: self.instructions, options: options)
        }
    }

    /// Returns typed output with diagnostics, tokenizing the same schema supplied to generation.
    public func respondDetailed<Content: Generable>(to prompt: String, generating: Content.Type,
        policy: RoutingPolicy = .automatic, deadline: RoutingDeadline? = nil, onAttempt: ((RoutingAttempt) -> Void)? = nil) async throws -> RoutingResult<Content> {
        try await execute(prompt: prompt, schema: Content.generationSchema, policy: policy, deadline: deadline, onAttempt: onAttempt) { route, options in
            try await self.backend.structured(route: route, prompt: prompt, instructions: self.instructions,
                options: options, generating: generating)
        }
    }

    /// Shares preflight and generation under the same request deadline and profile identity.
    private func execute<Value>(prompt: String, schema: GenerationSchema?, policy: RoutingPolicy,
        deadline: RoutingDeadline?, onAttempt: ((RoutingAttempt) -> Void)?,
        generate: @escaping @MainActor (InferenceRoute, GenerationOptions) async throws -> Value
    ) async throws -> RoutingResult<Value> {
        try await router.withRequest(deadline: deadline, onAttempt: onAttempt) { context in
            let prepared = try await self.prepare(prompt: prompt, schema: schema, policy: policy, context: context)
            return try await self.router.performDetailed(context: context, inputTokens: prepared.tokens,
                localContextCapacity: prepared.capacity, policy: policy,
                workload: .init(expectedOutputTokens: prepared.options.maximumResponseTokens), availability: prepared.availability, calibrationIdentifier: prepared.identity,
                shouldFallback: self.shouldFallback,
                cloud: { try await generate(.cloud, prepared.options) }, onDevice: { try await generate(.onDevice, prepared.options) })
        }
    }

    /// Accounts for local context only when permitted; tokenization failures cannot outlive the request.
    func prepare(prompt: String, schema: GenerationSchema?, policy: RoutingPolicy, context: RoutingRequestContext)
        async throws -> (tokens: Int, capacity: Int, availability: RoutingAvailability, options: GenerationOptions, identity: String) {
        try context.checkActive()
        var options = options
        let limit = options.maximumResponseTokens ?? router.configuration.localResponseReserve
        guard limit > 0 else { throw FoundationModelsAdapterError.invalidResponseLimit }
        options.maximumResponseTokens = limit
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let schemaData = try schema.map { try encoder.encode($0) }
        let schemaKey = schemaData.map { $0.base64EncodedString() } ?? "text"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unversioned"
        let identity = RoutingFingerprint.make([
            modelIdentifier, instructions ?? "", String(reflecting: options), schemaKey, appVersion,
        ])
        var availability = backend.availability(for: policy)
        var tokens = 0
        if availability.onDevice {
            do { tokens = try await backend.inputTokens(prompt: prompt, instructions: instructions, schema: schema) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try context.checkActive()
                let retry = availability.cloud && shouldFallback(.onDevice, error)
                try context.checkActive()
                guard retry else { throw error }
                availability = .init(onDevice: false, cloud: availability.cloud)
            }
        }
        try context.checkActive()
        return (tokens, availability.onDevice ? backend.localContextCapacity : 0, availability, options, identity)
    }
}
