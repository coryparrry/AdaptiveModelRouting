import AdaptiveModelRouting

/// Compiles the adapter, explicit configuration and detailed result through one package product and import.
@MainActor
public func generateSummary(_ prompt: String) async throws -> RoutingResult<String> {
    let configuration = RoutingConfiguration(customizing: .qualityFirst, failureBackoff: 120)
    let router = FoundationModelsRouter(workload: "single-import-summary", instructions: "Summarize clearly.",
        configuration: configuration, options: .init(maximumResponseTokens: 512))
    return try await router.respondDetailed(to: prompt, policy: .cloudRequired)
}

/// Compiles hard local privacy, deadline customization, memory-only storage and streaming with the same single import.
@MainActor
public func streamPrivateSummary(_ prompt: String) -> AsyncThrowingStream<RoutingStreamEvent<String>, any Error> {
    let router = FoundationModelsRouter(workload: "private-summary", persistence: .memoryOnly)
    return router.stream(to: prompt, policy: .localOnly, deadline: .after(.seconds(10)))
}
