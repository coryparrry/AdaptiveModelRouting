import Foundation

/// Constrains model quality independently of learned speed and provider health.
public nonisolated enum RoutingPolicy: Equatable, Sendable {
    /// Allows local calibration, selection and fallback when the app accepts local quality.
    case automatic
    /// Uses only cloud inference, including when offline, unavailable or failing.
    case cloudRequired
}

/// Describes expected generation work without storing prompts or generated content.
public nonisolated struct RoutingWorkload: Codable, Equatable, Sendable {
    /// Distinguishes new sessions from sessions whose existing context can affect latency.
    public enum SessionState: String, Codable, Sendable { case fresh, reused }

    /// Expected response length; nil compares only against other unspecified lengths.
    public let expectedOutputTokens: Int?
    /// The local provider's session state for this request.
    public let localSession: SessionState
    /// The cloud provider's session state for this request.
    public let cloudSession: SessionState

    /// Supplies a nonnegative expected response length and each provider's session state.
    public init(
        expectedOutputTokens: Int? = nil,
        localSession: SessionState = .fresh, cloudSession: SessionState = .fresh
    ) {
        if let expectedOutputTokens { precondition(expectedOutputTokens >= 0) }
        self.expectedOutputTokens = expectedOutputTokens
        self.localSession = localSession
        self.cloudSession = cloudSession
    }

    /// Compares response lengths and the selected provider's session state independently.
    func isComparable(to other: Self, model: InferenceRoute) -> Bool {
        let session = model == .cloud ? cloudSession : localSession
        let otherSession = model == .cloud ? other.cloudSession : other.localSession
        guard session == otherSession else { return false }
        switch (expectedOutputTokens, other.expectedOutputTokens) {
        case (nil, nil): return true
        case let (expected?, observed?):
            if expected == 0 { return observed == 0 }
            return (0.75...1.25).contains(Double(observed) / Double(expected))
        default: return false
        }
    }
}
