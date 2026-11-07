import Foundation
import FoundationModels
import AdaptiveModelRouting

/// Isolates SDK operations so adapter policy tests never require model downloads, entitlement or quota.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
protocol FoundationModelsBackend {
    var availability: RoutingAvailability { get }
    var localContextCapacity: Int { get }
    /// Counts the complete local transcript, including instructions and structured response schema.
    func inputTokens(prompt: String, instructions: String?, schema: GenerationSchema?) async throws -> Int
    /// Generates text in a new session without inheriting an unrelated provider's conversation.
    func text(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions) async throws -> String
    /// Generates the caller's concrete structured type in a new session.
    func structured<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
        options: GenerationOptions, generating: Content.Type) async throws -> Content
}

/// Uses official Apple APIs while keeping SDK instances outside the provider-independent router.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class AppleFoundationModelsBackend: FoundationModelsBackend {
    private let local: SystemLanguageModel
    private let cloud: PrivateCloudComputeLanguageModel

    /// Allows custom system models and PCC instances without accepting content-bearing sessions.
    init(local: SystemLanguageModel, cloud: PrivateCloudComputeLanguageModel) {
        self.local = local
        self.cloud = cloud
    }

    var availability: RoutingAvailability {
        let cloudAvailable: Bool
        if !cloud.isAvailable { cloudAvailable = false }
        else if case .limitReached = cloud.quotaUsage.status { cloudAvailable = false }
        else { cloudAvailable = true }
        return .init(onDevice: local.isAvailable, cloud: cloudAvailable)
    }

    var localContextCapacity: Int { local.contextSize }

    /// Tokenizes the same fresh transcript and response format used by generation, including framing.
    func inputTokens(prompt: String, instructions: String?, schema: GenerationSchema?) async throws -> Int {
        let session = LanguageModelSession(model: local, instructions: instructions)
        let request = Transcript.Prompt(segments: [.text(.init(content: prompt))],
            responseFormat: schema.map { .init(schema: $0) })
        return try await local.tokenCount(for: Array(session.transcript) + [.prompt(request)])
    }

    /// Creates an isolated session for plain-text output.
    func text(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions) async throws -> String {
        let session = session(route: route, instructions: instructions)
        return try await session.respond(to: prompt, options: options).content
    }

    /// Includes the generated type's schema in the provider's prompt and returns its decoded content.
    func structured<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
        options: GenerationOptions, generating: Content.Type) async throws -> Content {
        let session = session(route: route, instructions: instructions)
        return try await session.respond(to: prompt, generating: generating, options: options).content
    }

    /// Keeps provider histories independent and avoids replaying side effects between providers.
    private func session(route: InferenceRoute, instructions: String?) -> LanguageModelSession {
        switch route {
        case .onDevice: LanguageModelSession(model: local, instructions: instructions)
        case .cloud: LanguageModelSession(model: cloud, instructions: instructions)
        }
    }
}
