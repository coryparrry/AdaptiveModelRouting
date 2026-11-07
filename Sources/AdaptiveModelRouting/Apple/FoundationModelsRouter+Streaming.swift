import Foundation
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
extension FoundationModelsRouter {
    /// Streams cumulative text with bounded buffering and one deadline spanning preflight and generation.
    public func stream(to prompt: String, policy: RoutingPolicy = .automatic, deadline: RoutingDeadline? = nil,
        onAttempt: ((RoutingAttempt) -> Void)? = nil) -> AsyncThrowingStream<RoutingStreamEvent<String>, any Error> {
        RoutingStreamFactory.make { continuation in
            try await self.router.withRequest(deadline: deadline, onAttempt: onAttempt) { context in
                let request = try await self.prepare(prompt: prompt, schema: nil, policy: policy, context: context)
                return try await self.router.performStreaming(context: context, inputTokens: request.tokens,
                    localContextCapacity: request.capacity, policy: policy,
                    workload: .init(expectedOutputTokens: request.options.maximumResponseTokens), availability: request.availability, calibrationIdentifier: request.identity,
                    shouldFallback: self.shouldFallback, continuation: continuation,
                    cloud: { self.backend.textStream(route: .cloud, prompt: prompt, instructions: self.instructions, options: request.options) },
                    onDevice: { self.backend.textStream(route: .onDevice, prompt: prompt, instructions: self.instructions, options: request.options) })
            }
        }
    }

    /// Streams native partial fields; the completed result contains the last partial snapshot, not a separate generation.
    public func stream<Content: Generable>(to prompt: String, generating: Content.Type,
        policy: RoutingPolicy = .automatic, deadline: RoutingDeadline? = nil, onAttempt: ((RoutingAttempt) -> Void)? = nil
    ) -> AsyncThrowingStream<RoutingStreamEvent<Content.PartiallyGenerated>, any Error> where Content.PartiallyGenerated: Sendable {
        RoutingStreamFactory.make { continuation in
            try await self.router.withRequest(deadline: deadline, onAttempt: onAttempt) { context in
                let request = try await self.prepare(prompt: prompt, schema: Content.generationSchema, policy: policy, context: context)
                return try await self.router.performStreaming(context: context, inputTokens: request.tokens,
                    localContextCapacity: request.capacity, policy: policy,
                    workload: .init(expectedOutputTokens: request.options.maximumResponseTokens), availability: request.availability, calibrationIdentifier: request.identity,
                    shouldFallback: self.shouldFallback, continuation: continuation,
                    cloud: { self.backend.structuredStream(route: .cloud, prompt: prompt, instructions: self.instructions,
                        options: request.options, generating: generating) },
                    onDevice: { self.backend.structuredStream(route: .onDevice, prompt: prompt, instructions: self.instructions,
                        options: request.options, generating: generating) })
            }
        }
    }
}
