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
    /// Minimum comparable observations required per provider before using latency predictions.
    public let minimumSamples: Int
    /// Maximum recent comparable observations used in each prediction.
    public let predictionSampleLimit: Int
    /// Permitted fractional difference in input and expected output sizes.
    public let sizeTolerance: Double
    /// Duration of provider-health backoff after a recoverable failure.
    public let failureBackoff: TimeInterval
    /// Interval before probing cloud again when local inference usually wins.
    public let cloudRetryInterval: TimeInterval
    /// Interval before refreshing local calibration when cloud usually wins.
    public let localRefreshInterval: TimeInterval
    /// Maximum age of timing observations used for prediction.
    public let sampleLifetime: TimeInterval
    /// Number of weighted standard deviations applied to each provider's latency estimate.
    public let variabilityAllowance: Double

    /// Preserves the original cloud-first policy and one-deviation timing allowance.
    public static var balanced: Self { .init() }
    /// Requires more observations and a larger local advantage before departing from cloud preference.
    public static var qualityFirst: Self {
        .init(minimumLocalSavingSeconds: 0.75, minimumLocalSavingFraction: 0.4,
            minimumSamples: 5, variabilityAllowance: 1.5)
    }
    /// Accepts a smaller demonstrated local advantage while preserving calibration and quality constraints.
    public static var latencyFirst: Self {
        .init(minimumLocalSavingSeconds: 0.1, minimumLocalSavingFraction: 0.1, variabilityAllowance: 0.5)
    }

    /// Creates a policy; reserves and margins must be nonnegative, and the slow limit positive.
    public init(
        localResponseReserve: Int = 400,
        minimumLocalSavingSeconds: TimeInterval = 0.35,
        minimumLocalSavingFraction: Double = 0.25,
        slowCloudAfter: Duration = .seconds(20),
        minimumSamples: Int = 3, predictionSampleLimit: Int = 6, sizeTolerance: Double = 0.25,
        failureBackoff: TimeInterval = 60, cloudRetryInterval: TimeInterval = 600,
        localRefreshInterval: TimeInterval = 1_800, sampleLifetime: TimeInterval = 7 * 86_400,
        variabilityAllowance: Double = 1
    ) {
        precondition(localResponseReserve >= 0)
        precondition(minimumLocalSavingSeconds.isFinite && minimumLocalSavingSeconds >= 0)
        precondition(minimumLocalSavingFraction.isFinite && (0...1).contains(minimumLocalSavingFraction))
        precondition(slowCloudAfter > .zero)
        precondition(minimumSamples > 0 && predictionSampleLimit >= minimumSamples && predictionSampleLimit <= 128)
        precondition(sizeTolerance.isFinite && (0...1).contains(sizeTolerance))
        for interval in [failureBackoff, cloudRetryInterval, localRefreshInterval, sampleLifetime] {
            precondition(interval.isFinite && interval > 0)
        }
        precondition(variabilityAllowance.isFinite && variabilityAllowance >= 0)
        self.localResponseReserve = localResponseReserve
        self.minimumLocalSavingSeconds = minimumLocalSavingSeconds
        self.minimumLocalSavingFraction = minimumLocalSavingFraction
        self.slowCloudAfter = slowCloudAfter
        self.minimumSamples = minimumSamples
        self.predictionSampleLimit = predictionSampleLimit
        self.sizeTolerance = sizeTolerance
        self.failureBackoff = failureBackoff
        self.cloudRetryInterval = cloudRetryInterval
        self.localRefreshInterval = localRefreshInterval
        self.sampleLifetime = sampleLifetime
        self.variabilityAllowance = variabilityAllowance
    }

    /// Overrides selected preset values while retaining validation and all unspecified settings.
    public init(
        customizing preset: Self, localResponseReserve: Int? = nil,
        minimumLocalSavingSeconds: TimeInterval? = nil, minimumLocalSavingFraction: Double? = nil,
        slowCloudAfter: Duration? = nil, minimumSamples: Int? = nil, predictionSampleLimit: Int? = nil,
        sizeTolerance: Double? = nil, failureBackoff: TimeInterval? = nil,
        cloudRetryInterval: TimeInterval? = nil, localRefreshInterval: TimeInterval? = nil,
        sampleLifetime: TimeInterval? = nil, variabilityAllowance: Double? = nil
    ) {
        self.init(localResponseReserve: localResponseReserve ?? preset.localResponseReserve,
            minimumLocalSavingSeconds: minimumLocalSavingSeconds ?? preset.minimumLocalSavingSeconds,
            minimumLocalSavingFraction: minimumLocalSavingFraction ?? preset.minimumLocalSavingFraction,
            slowCloudAfter: slowCloudAfter ?? preset.slowCloudAfter,
            minimumSamples: minimumSamples ?? preset.minimumSamples,
            predictionSampleLimit: predictionSampleLimit ?? preset.predictionSampleLimit,
            sizeTolerance: sizeTolerance ?? preset.sizeTolerance,
            failureBackoff: failureBackoff ?? preset.failureBackoff,
            cloudRetryInterval: cloudRetryInterval ?? preset.cloudRetryInterval,
            localRefreshInterval: localRefreshInterval ?? preset.localRefreshInterval,
            sampleLifetime: sampleLifetime ?? preset.sampleLifetime,
            variabilityAllowance: variabilityAllowance ?? preset.variabilityAllowance)
    }
}
