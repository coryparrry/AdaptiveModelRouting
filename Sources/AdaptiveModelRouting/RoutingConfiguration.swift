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

/// Controls whether calibration can run both inference providers for the same request.
public nonisolated enum RoutingCalibration: Sendable, Equatable {
    /// Runs the other provider during initial learning and every N eligible requests thereafter (one by default).
    /// Local rechecks use device compute; optional cloud calls also obey cloudRetryInterval.
    /// Probe results train timings without replacing the selected provider's answer.
    case paired(refreshEvery: Int = 1, timeout: Duration = .seconds(60))
    /// Learns from one selected provider at a time, including occasional local exploration.
    case singleProvider
}

/// Tunes latency selection, ongoing calibration and context reservation for a workload.
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
    /// Minimum time since any cloud use before optional cloud calibration or single-provider refresh.
    public let cloudRetryInterval: TimeInterval
    /// Interval before refreshing local calibration when cloud usually wins.
    public let localRefreshInterval: TimeInterval
    /// Maximum age of timing observations used for prediction.
    public let sampleLifetime: TimeInterval
    /// Number of weighted standard deviations applied to each provider's latency estimate.
    public let variabilityAllowance: Double
    /// Bounds preflight, generation and recovery together; unlimited must be selected explicitly.
    public let requestDeadline: RoutingDeadline
    /// Paired calibration is automatic by default; use singleProvider for operations with side effects.
    public let calibration: RoutingCalibration
    /// Protects remaining cloud quota by excluding approaching-limit cloud from automatic requests.
    /// Explicit cloudRequired requests may still use approaching quota, but never exhausted quota.
    /// Also confirms mixed paired evidence before a zero-margin paid promotion.
    public let conserveCloudQuota: Bool
    /// Halves the weight of older measurements across this elapsed interval, in addition to recency rank.
    public let predictionHalfLife: TimeInterval

    /// Chooses the lowest weighted latency after calibration, without margins or variability penalties.
    public static var fastest: Self { .init() }
    /// Opts into a 350 ms/25% local saving requirement and a one-deviation cloud preference.
    public static var balanced: Self {
        .init(minimumLocalSavingSeconds: 0.35, minimumLocalSavingFraction: 0.25, variabilityAllowance: 1)
    }
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
        minimumLocalSavingSeconds: TimeInterval = 0,
        minimumLocalSavingFraction: Double = 0,
        slowCloudAfter: Duration = .seconds(20),
        minimumSamples: Int = 3, predictionSampleLimit: Int = 6, sizeTolerance: Double = 0.25,
        failureBackoff: TimeInterval = 60, cloudRetryInterval: TimeInterval = 600,
        localRefreshInterval: TimeInterval = 1_800, sampleLifetime: TimeInterval = 7 * 86_400,
        variabilityAllowance: Double = 0, requestDeadline: RoutingDeadline = .after(.seconds(60)),
        calibration: RoutingCalibration = .paired(), conserveCloudQuota: Bool = true,
        predictionHalfLife: TimeInterval = 300
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
        precondition(predictionHalfLife.isFinite && predictionHalfLife > 0)
        if case .after(let duration) = requestDeadline { precondition(duration > .zero) }
        if case .paired(let frequency, let timeout) = calibration {
            precondition(frequency > 0 && timeout > .zero)
        }
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
        self.requestDeadline = requestDeadline
        self.calibration = calibration
        self.conserveCloudQuota = conserveCloudQuota
        self.predictionHalfLife = predictionHalfLife
    }

    /// Overrides selected preset values while retaining validation and all unspecified settings.
    public init(
        customizing preset: Self, localResponseReserve: Int? = nil,
        minimumLocalSavingSeconds: TimeInterval? = nil, minimumLocalSavingFraction: Double? = nil,
        slowCloudAfter: Duration? = nil, minimumSamples: Int? = nil, predictionSampleLimit: Int? = nil,
        sizeTolerance: Double? = nil, failureBackoff: TimeInterval? = nil,
        cloudRetryInterval: TimeInterval? = nil, localRefreshInterval: TimeInterval? = nil,
        sampleLifetime: TimeInterval? = nil, variabilityAllowance: Double? = nil,
        requestDeadline: RoutingDeadline? = nil, calibration: RoutingCalibration? = nil,
        conserveCloudQuota: Bool? = nil, predictionHalfLife: TimeInterval? = nil
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
            variabilityAllowance: variabilityAllowance ?? preset.variabilityAllowance,
            requestDeadline: requestDeadline ?? preset.requestDeadline,
            calibration: calibration ?? preset.calibration,
            conserveCloudQuota: conserveCloudQuota ?? preset.conserveCloudQuota,
            predictionHalfLife: predictionHalfLife ?? preset.predictionHalfLife)
    }
}
