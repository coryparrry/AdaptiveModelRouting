import Foundation
import FoundationModels

/// Isolates SDK operations so adapter policy tests never require model downloads, entitlement or quota.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
protocol FoundationModelsBackend {
    var availability: RoutingAvailability { get }
    /// Inspects only providers permitted by the request's hard routing policy.
    func availability(for policy: RoutingPolicy) -> RoutingAvailability
    var localContextCapacity: Int { get }
    /// Counts the complete local transcript, including instructions and structured response schema.
    func inputTokens(prompt: String, instructions: String?, schema: GenerationSchema?) async throws -> Int
    /// Generates text in a new session without inheriting an unrelated provider's conversation.
    func text(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions) async throws -> String
    /// Generates the caller's concrete structured type in a new session.
    func structured<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
        options: GenerationOptions, generating: Content.Type) async throws -> Content
    /// Produces cumulative text snapshots and honors consumer cancellation.
    func textStream(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions)
        -> AsyncThrowingStream<String, any Error>
    /// Produces native partially-generated values for Sendable generated models.
    func structuredStream<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
        options: GenerationOptions, generating: Content.Type) -> AsyncThrowingStream<Content.PartiallyGenerated, any Error>
        where Content.PartiallyGenerated: Sendable
}

/// Uses official Apple APIs while keeping SDK instances outside the provider-independent router.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class AppleFoundationModelsBackend: FoundationModelsBackend {
    private let local: SystemLanguageModel
    private var cloud: PrivateCloudComputeLanguageModel?

    /// Allows custom system models and PCC instances without accepting content-bearing sessions.
    init(local: SystemLanguageModel, cloud: PrivateCloudComputeLanguageModel?) {
        self.local = local
        self.cloud = cloud
    }

    var availability: RoutingAvailability { availability(for: .automatic) }

    /// Local-only checks never create or inspect a PCC model; cloud-required checks do not inspect local readiness.
    func availability(for policy: RoutingPolicy) -> RoutingAvailability {
        if policy == .localOnly { return .init(onDevice: local.isAvailable, cloud: false) }
        let cloud = cloudModel()
        let cloudAvailable: Bool
        if !cloud.isAvailable { cloudAvailable = false }
        else if case .limitReached = cloud.quotaUsage.status { cloudAvailable = false }
        else { cloudAvailable = true }
        return .init(onDevice: policy != .cloudRequired && local.isAvailable, cloud: cloudAvailable)
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
        case .cloud: LanguageModelSession(model: cloudModel(), instructions: instructions)
        }
    }

    /// Lazily creates PCC only when an allowed cloud operation needs it.
    private func cloudModel() -> PrivateCloudComputeLanguageModel {
        if let cloud { return cloud }
        let model = PrivateCloudComputeLanguageModel()
        cloud = model
        return model
    }

    /// Uses the SDK's native text stream without retaining completed prompts in the router.
    func textStream(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions)
        -> AsyncThrowingStream<String, any Error> {
        let session = session(route: route, instructions: instructions)
        return bridge(session: session, stream: session.streamResponse(to: prompt, options: options))
    }

    /// Exposes native partial content while keeping the concrete schema in preflight and generation.
    func structuredStream<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
        options: GenerationOptions, generating: Content.Type) -> AsyncThrowingStream<Content.PartiallyGenerated, any Error>
        where Content.PartiallyGenerated: Sendable {
        let session = session(route: route, instructions: instructions)
        return bridge(session: session, stream: session.streamResponse(to: prompt, generating: generating, options: options))
    }

    /// Coalesces cumulative SDK snapshots and cancels the SDK iterator when the consumer terminates.
    private func bridge<Content: Generable>(session: LanguageModelSession, stream: LanguageModelSession.ResponseStream<Content>)
        -> AsyncThrowingStream<Content.PartiallyGenerated, any Error> where Content.PartiallyGenerated: Sendable {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let producer = Task { @MainActor in
                defer { withExtendedLifetime(session) {} }
                do {
                    for try await snapshot in stream {
                        try Task.checkCancellation()
                        if case .terminated = continuation.yield(snapshot.content) { throw CancellationError() }
                    }
                    try Task.checkCancellation()
                    let final = try await stream.collect()
                    try Task.checkCancellation()
                    continuation.yield(final.content.asPartiallyGenerated())
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension FoundationModelsBackend {
    /// Applies request policy to injected readiness without requiring production SDK objects in tests.
    func availability(for policy: RoutingPolicy) -> RoutingAvailability {
        let value = availability
        return .init(onDevice: policy != .cloudRequired && value.onDevice,
            cloud: policy != .localOnly && value.cloud)
    }

    /// Supplies a one-snapshot stream for lightweight injected test providers.
    func textStream(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions)
        -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let producer = Task { @MainActor in
                do {
                    continuation.yield(try await text(route: route, prompt: prompt, instructions: instructions, options: options))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Supplies fully-generated content as one native partial value for injected tests.
    func structuredStream<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
        options: GenerationOptions, generating: Content.Type) -> AsyncThrowingStream<Content.PartiallyGenerated, any Error>
        where Content.PartiallyGenerated: Sendable {
        AsyncThrowingStream { continuation in
            let producer = Task { @MainActor in
                do {
                    let value = try await structured(route: route, prompt: prompt, instructions: instructions,
                        options: options, generating: generating)
                    continuation.yield(value.asPartiallyGenerated())
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}
