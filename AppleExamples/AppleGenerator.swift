import FoundationModels
import AdaptiveFoundationModels
import AdaptiveModelRouting

/// Demonstrates app-owned structured output without manually wiring two generation closures.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
public final class AppleGenerator {
    /// A structured response whose schema is included in local context accounting.
    @Generable
    public struct Summary {
        public var headline: String
        public var points: [String]
    }

    private let router: FoundationModelsRouter

    /// Keeps calibration for one summary workload and applies a validated preset override.
    public init() {
        router = FoundationModelsRouter(workload: "summaries", instructions: "Summarize accurately and concisely.",
            configuration: .init(customizing: .qualityFirst, failureBackoff: 120),
            options: .init(maximumResponseTokens: 512))
    }

    /// Returns a typed summary with the initial selection, actual provider and attempt metadata.
    public func summarize(_ text: String) async throws -> RoutingResult<Summary> {
        try await router.respondDetailed(to: text, generating: Summary.self)
    }
}
