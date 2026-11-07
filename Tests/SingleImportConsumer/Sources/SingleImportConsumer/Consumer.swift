import AdaptiveModelRouting

/// Compiles the adapter, explicit configuration and detailed result through one package product and import.
@MainActor
public func generateSummary(_ prompt: String) async throws -> RoutingResult<String> {
    let configuration = RoutingConfiguration(customizing: .qualityFirst, failureBackoff: 120)
    let router = FoundationModelsRouter(workload: "single-import-summary", instructions: "Summarize clearly.",
        configuration: configuration, options: .init(maximumResponseTokens: 512))
    return try await router.respondDetailed(to: prompt, policy: .cloudRequired)
}
