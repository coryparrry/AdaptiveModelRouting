import AdaptiveModelRouting

/// Compiles owned custom streaming through the same product/import without requiring another SDK adapter.
@MainActor
public func streamOwnedProviderExample() -> AsyncThrowingStream<RoutingStreamEvent<String>, any Error> {
    let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
    return router.streamOwned(inputTokens: 100, localContextCapacity: 8_192,
        cloud: { RoutingProviderStream { $0.yield("cloud") } },
        onDevice: { RoutingProviderStream { $0.yield("local") } })
}

/// Compiles the adapter, explicit configuration and detailed result through one package product and import.
@MainActor
public func generateSummary(_ prompt: String) async throws -> RoutingResult<String> {
    let configuration = RoutingConfiguration(customizing: .qualityFirst, failureBackoff: 120,
        calibration: .paired(refreshEvery: 8, timeout: .seconds(20)),
        conserveCloudQuota: true, predictionHalfLife: 300)
    let router = FoundationModelsRouter(workload: "single-import-summary", instructions: "Summarize clearly.",
        configuration: configuration, options: .init(maximumResponseTokens: 512))
    let quota: CloudQuotaStatus = .approachingLimit
    _ = RoutingAvailability(cloudQuota: quota)
    let result = try await router.respondDetailed(to: prompt)
    await router.waitForCalibration()
    _ = router.lastCalibrationAttempt
    router.cancelCalibration()
    return result
}

/// Compiles hard local privacy, deadline customization, memory-only storage and streaming with the same single import.
@MainActor
public func streamPrivateSummary(_ prompt: String) -> AsyncThrowingStream<RoutingStreamEvent<String>, any Error> {
    let router = FoundationModelsRouter(workload: "private-summary", persistence: .memoryOnly)
    return router.stream(to: prompt, policy: .localOnly, deadline: .after(.seconds(10)))
}
