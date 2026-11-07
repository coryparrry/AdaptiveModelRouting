import AdaptiveModelRouting

/// A client-owned generation service; model SDKs and prompts stay outside the routing package.
@MainActor
public final class Generator {
    private let router: AdaptiveRouter

    /// Keeps one router alive for this workload so path observation and calibration can accumulate.
    public init(router: AdaptiveRouter) { self.router = router }

    /// Uses caller-counted tokens and closures, returning nil when no permitted whole-request result is available.
    public func generate(
        inputTokens: Int, localContextCapacity: Int,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init(),
        cloud: @escaping @MainActor () async throws -> String?,
        onDevice: @escaping @MainActor () async throws -> String
    ) async throws -> String? {
        try await router.respond(inputTokens: inputTokens, localContextCapacity: localContextCapacity,
            policy: policy, workload: workload, cloud: cloud, onDevice: onDevice)
    }
}
