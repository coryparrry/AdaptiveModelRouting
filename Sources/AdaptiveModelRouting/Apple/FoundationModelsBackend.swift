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
        -> RoutingProviderStream<String>
    /// Produces native partially-generated values for Sendable generated models.
    func structuredStream<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
        options: GenerationOptions, generating: Content.Type) -> RoutingProviderStream<Content.PartiallyGenerated>
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
        let quota: CloudQuotaStatus
        if !cloud.isAvailable { cloudAvailable = false; quota = .unknown }
        else {
            switch cloud.quotaUsage.status {
            case .belowLimit(let usage): cloudAvailable = true; quota = usage.isApproachingLimit ? .approachingLimit : .available
            case .limitReached: cloudAvailable = false; quota = .exhausted
            @unknown default: cloudAvailable = false; quota = .unknown
            }
        }
        return .init(onDevice: policy != .cloudRequired && local.isAvailable, cloud: cloudAvailable, cloudQuota: quota)
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
        let trace = NativeInferenceTrace(route: route, format: "text")
        do {
            let content = try await session.respond(to: prompt, options: options).content
            trace.finish(succeeded: true)
            return content
        } catch { trace.finish(succeeded: false); throw error }
    }

    /// Includes the generated type's schema in the provider's prompt and returns its decoded content.
    func structured<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
        options: GenerationOptions, generating: Content.Type) async throws -> Content {
        let session = session(route: route, instructions: instructions)
        let trace = NativeInferenceTrace(route: route, format: "structured")
        do {
            let content = try await session.respond(to: prompt, generating: generating, options: options).content
            trace.finish(succeeded: true)
            return content
        } catch { trace.finish(succeeded: false); throw error }
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
        -> RoutingProviderStream<String> {
        let session = session(route: route, instructions: instructions)
        let trace = NativeInferenceTrace(route: route, format: "textStream")
        return bridge(session: session, stream: session.streamResponse(to: prompt, options: options), trace: trace)
    }

    /// Exposes native partial content while keeping the concrete schema in preflight and generation.
    func structuredStream<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
        options: GenerationOptions, generating: Content.Type) -> RoutingProviderStream<Content.PartiallyGenerated>
        where Content.PartiallyGenerated: Sendable {
        let session = session(route: route, instructions: instructions)
        let trace = NativeInferenceTrace(route: route, format: "structuredStream")
        return bridge(session: session, stream: session.streamResponse(to: prompt, generating: generating, options: options), trace: trace)
    }

    /// Coalesces cumulative SDK snapshots and cancels the SDK iterator when the consumer terminates.
    private func bridge<Content: Generable>(session: LanguageModelSession, stream: LanguageModelSession.ResponseStream<Content>,
        trace: NativeInferenceTrace)
        -> RoutingProviderStream<Content.PartiallyGenerated> where Content.PartiallyGenerated: Sendable {
        RoutingProviderStream { continuation in
            var succeeded = false
            defer { trace.finish(succeeded: succeeded); withExtendedLifetime(session) {} }
            for try await snapshot in stream {
                try Task.checkCancellation()
                if case .terminated = continuation.yield(snapshot.content) { throw CancellationError() }
            }
            try Task.checkCancellation()
            let final = try await stream.collect()
            try Task.checkCancellation()
            continuation.yield(final.content.asPartiallyGenerated())
            succeeded = true
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension FoundationModelsBackend {
    /// Applies request policy to injected readiness without requiring production SDK objects in tests.
    func availability(for policy: RoutingPolicy) -> RoutingAvailability {
        let value = availability
        return .init(onDevice: policy != .cloudRequired && value.onDevice,
            cloud: policy != .localOnly && value.cloud, cloudQuota: value.cloudQuota)
    }

    /// Supplies a one-snapshot stream for lightweight injected test providers.
    func textStream(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions)
        -> RoutingProviderStream<String> {
        RoutingProviderStream { continuation in
            let value = try await text(route: route, prompt: prompt, instructions: instructions, options: options)
            try Task.checkCancellation()
            continuation.yield(value)
        }
    }

    /// Supplies fully-generated content as one native partial value for injected tests.
    func structuredStream<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
        options: GenerationOptions, generating: Content.Type) -> RoutingProviderStream<Content.PartiallyGenerated>
        where Content.PartiallyGenerated: Sendable {
        RoutingProviderStream { continuation in
            let value = try await structured(route: route, prompt: prompt, instructions: instructions,
                options: options, generating: generating)
            try Task.checkCancellation()
            continuation.yield(value.asPartiallyGenerated())
        }
    }
}
