import AdaptiveModelRouting

/// A client-owned generation service; model SDKs and prompts stay outside the routing package.
@MainActor
public final class Generator {
    private let router: AdaptiveRouter

    /// Keeps one router alive for this workload so path observation and calibration can accumulate.
    public init(router: AdaptiveRouter) { self.router = router }

    /// Uses caller-counted tokens and provider closures, returning nil if local chunking is required.
    public func generate(
        inputTokens: Int, localContextCapacity: Int,
        cloud: () async throws -> String?,
        onDevice: () async throws -> String
    ) async throws -> String? {
        try await router.respond(inputTokens: inputTokens, localContextCapacity: localContextCapacity,
            cloud: cloud, onDevice: onDevice)
    }
}
