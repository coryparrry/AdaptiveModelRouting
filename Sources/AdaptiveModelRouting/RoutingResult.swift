import Foundation

/// Provider readiness supplied by an adapter or app without recording identity or model content.
public nonisolated struct RoutingAvailability: Equatable, Sendable {
    public let onDevice: Bool
    public let cloud: Bool

    /// Defaults to callable providers for compatibility with the closure-based API.
    public init(onDevice: Bool = true, cloud: Bool = true) {
        self.onDevice = onDevice
        self.cloud = cloud
    }
}

/// A weighted latency prediction and its recent variability, expressed in seconds.
public nonisolated struct RoutingEstimate: Equatable, Sendable {
    public let seconds: Double
    public let deviation: Double
    public let sampleCount: Int
}

/// Explains why a provider was preferred before execution or fallback.
public nonisolated enum RoutingReason: String, Sendable {
    case cloudRequired, cloudPreferred, localCalibration, localFaster, offline
    case cloudBackoff, localBackoff, insufficientEvidence, cloudRefresh
    case localUnavailable, cloudUnavailable, localContextExceeded, noAvailableProvider
}

/// Describes the original selection; the result's actual route may differ after recovery.
public nonisolated struct RoutingDecision: Equatable, Sendable {
    public let route: InferenceRoute
    public let reason: RoutingReason
    public let localEstimate: RoutingEstimate?
    public let cloudEstimate: RoutingEstimate?

    /// Creates a content-free explanation with optional predictions when enough evidence exists.
    public init(route: InferenceRoute, reason: RoutingReason,
        localEstimate: RoutingEstimate? = nil, cloudEstimate: RoutingEstimate? = nil) {
        self.route = route
        self.reason = reason
        self.localEstimate = localEstimate
        self.cloudEstimate = cloudEstimate
    }
}

/// Timing and disposition for one attempted operation, without prompts, outputs or raw errors.
public nonisolated struct RoutingAttempt: Equatable, Sendable {
    /// A nil cloud response is unavailable rather than a successful inference.
    public enum Outcome: String, Sendable { case succeeded, unavailable, failed, cancelled }
    public let route: InferenceRoute
    public let seconds: Double
    public let outcome: Outcome
}

/// Distinguishes a usable result from a caller-owned recovery or availability decision.
public nonisolated enum RoutingResultStatus: Equatable, Sendable {
    case completed
    case requiresChunking
    case unavailable
}

/// Returns the selected policy, actual provider and attempt history alongside generic model output.
public nonisolated struct RoutingResult<Value> {
    public let value: Value?
    public let status: RoutingResultStatus
    public let decision: RoutingDecision
    public let route: InferenceRoute?
    public let attempts: [RoutingAttempt]
    public let availability: RoutingAvailability
    /// Indicates execution reached a provider other than the original preference.
    public var didFallback: Bool { attempts.contains { $0.route != decision.route } }
}

extension RoutingResult: Sendable where Value: Sendable {}
