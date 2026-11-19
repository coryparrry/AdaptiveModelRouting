import Foundation
import FoundationModels

/// Preserves explicit throttling deadlines from the Apple SDK without inspecting error descriptions.
@available(iOS 27.0, macOS 27.0, *)
extension LanguageModelError: RoutingRetryAfterProviding {
    /// Extracts only a structured rate-limit reset date; other errors use normal failure backoff.
    var routingRetryAfter: Date? {
        if case .rateLimited(let context) = self { return context.resetDate }
        return nil
    }
}

/// Treats a PCC quota reset as provider-wide state rather than a property of the current Wi-Fi route.
@available(iOS 27.0, macOS 27.0, *)
extension PrivateCloudComputeLanguageModel.Error: RoutingRetryAfterProviding {
    /// Retains quota reset information without recording private diagnostic strings.
    var routingRetryAfter: Date? {
        if case .quotaLimitReached(let context) = self { return context.resetDate }
        return nil
    }
}
