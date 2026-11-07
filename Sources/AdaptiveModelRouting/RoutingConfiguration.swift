import Foundation

/// An execution lane supplied by the app, independent of any model SDK.
public nonisolated enum InferenceRoute: String, Codable, Sendable {
    /// Inference performed locally on the current device.
    case onDevice
    /// The app's preferred cloud model, such as Apple's Private Cloud Compute model.
    case cloud

    /// Reads caches from both the package and its original PCC-specific prototype.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "pcc" { self = .cloud }
        else if let route = Self(rawValue: value) { self = route }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown inference route.") }
    }
}

/// Tunes the cloud-quality preference and context reservation for a particular workload.
public nonisolated struct RoutingConfiguration: Sendable {
    /// Tokens reserved for local response generation and prompt framing.
    public let localResponseReserve: Int
    /// Absolute latency advantage required before preferring local inference.
    public let minimumLocalSavingSeconds: TimeInterval
    /// Fraction of cloud latency that local inference must save.
    public let minimumLocalSavingFraction: Double
    /// Time after which an unfinished cloud request triggers health backoff.
    public let slowCloudAfter: Duration

    /// Creates a policy; reserves and margins must be nonnegative, and the slow limit positive.
    public init(
        localResponseReserve: Int = 400,
        minimumLocalSavingSeconds: TimeInterval = 0.35,
        minimumLocalSavingFraction: Double = 0.25,
        slowCloudAfter: Duration = .seconds(20)
    ) {
        precondition(localResponseReserve >= 0)
        precondition(minimumLocalSavingSeconds.isFinite && minimumLocalSavingSeconds >= 0)
        precondition(minimumLocalSavingFraction.isFinite && (0...1).contains(minimumLocalSavingFraction))
        precondition(slowCloudAfter > .zero)
        self.localResponseReserve = localResponseReserve
        self.minimumLocalSavingSeconds = minimumLocalSavingSeconds
        self.minimumLocalSavingFraction = minimumLocalSavingFraction
        self.slowCloudAfter = slowCloudAfter
    }
}
