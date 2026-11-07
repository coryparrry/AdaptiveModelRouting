import Foundation

/// Learns latency on this device without storing meeting text or network identifiers.
public nonisolated struct PerformanceProfile: Codable, Sendable {
    /// Coarse network properties, available without Wi-Fi identity or location permission.
    public struct Connection: Codable, Equatable, Sendable {
        /// Separates offline, mobile and fixed connections without retaining their identity.
        public enum Kind: String, Codable, Sendable { case unknown, offline, wifi, cellular, wired, other }
        public var kind: Kind
        public var expensive = false
        public var constrained = false

        /// Describes a coarse path without Wi-Fi names, addresses or location access.
        public init(kind: Kind, expensive: Bool = false, constrained: Bool = false) {
            self.kind = kind
            self.expensive = expensive
            self.constrained = constrained
        }
    }

    /// A completed inference's size and elapsed time; no generated content is retained.
    public struct Sample: Codable, Sendable {
        public let model: InferenceRoute
        public let tokens: Int
        public let seconds: Double
        public let connection: Connection
        public let date: Date
        /// Missing metadata in older caches represents fresh sessions with unspecified output size.
        public let workload: RoutingWorkload?
    }

    /// Prevents repeatedly attempting cloud inference on a currently failing connection.
    public struct Failure: Codable, Sendable {
        public let model: InferenceRoute
        public let connection: Connection
        public let date: Date
    }

    public private(set) var samples: [Sample] = []
    public private(set) var failures: [Failure] = []
    /// Creates an empty history that initially prefers the cloud model.
    public init() {}

    /// Returns the preferred lane using the same policy as the explainable decision API.
    public func choose(
        inputTokens: Int, localCapacity: Int, connection: Connection, now: Date,
        configuration: RoutingConfiguration = .init(),
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init()
    ) -> InferenceRoute {
        decision(inputTokens: inputTokens, localCapacity: localCapacity, connection: connection,
            now: now, configuration: configuration, policy: policy, workload: workload).route
    }

    /// Explains quality, availability, health, calibration and predicted-latency decisions.
    public func decision(
        inputTokens: Int, localCapacity: Int, connection: Connection, now: Date,
        configuration: RoutingConfiguration = .balanced, policy: RoutingPolicy = .automatic,
        workload: RoutingWorkload = .init(), availability: RoutingAvailability = .init()
    ) -> RoutingDecision {
        if policy == .cloudRequired { return .init(route: .cloud, reason: .cloudRequired) }
        if !availability.onDevice && !availability.cloud { return .init(route: .cloud, reason: .noAvailableProvider) }
        if connection.kind == .offline { return .init(route: .onDevice, reason: .offline) }
        if !availability.onDevice { return .init(route: .cloud, reason: .localUnavailable) }
        if !availability.cloud { return .init(route: .onDevice, reason: .cloudUnavailable) }
        if failures.contains(where: {
            $0.model == .cloud && $0.connection == connection && now.timeIntervalSince($0.date) >= 0
                && now.timeIntervalSince($0.date) < configuration.failureBackoff
        }) { return .init(route: .onDevice, reason: .cloudBackoff) }
        guard InferenceExecutor.fitsLocal(inputTokens: inputTokens, localCapacity: localCapacity,
            responseReserve: max(configuration.localResponseReserve, workload.expectedOutputTokens ?? 0))
            else { return .init(route: .cloud, reason: .localContextExceeded) }
        if failures.contains(where: {
            $0.model == .onDevice && now.timeIntervalSince($0.date) >= 0
                && now.timeIntervalSince($0.date) < configuration.failureBackoff
        }) { return .init(route: .cloud, reason: .localBackoff) }
        let localSamples = comparable(.onDevice, tokens: inputTokens, workload: workload,
            connection: connection, now: now, configuration: configuration)
        let cloudSamples = comparable(.cloud, tokens: inputTokens, workload: workload,
            connection: connection, now: now, configuration: configuration)
        let lastLocal = localSamples.first?.date ?? .distantPast
        if (localSamples.count < configuration.minimumSamples
            || now.timeIntervalSince(lastLocal) >= configuration.localRefreshInterval),
           cloudSamples.filter({ $0.date > lastLocal }).count >= configuration.minimumSamples {
            return .init(route: .onDevice, reason: .localCalibration)
        }
        guard let local = estimate(localSamples, configuration: configuration),
              let cloud = estimate(cloudSamples, configuration: configuration)
            else { return .init(route: .cloud, reason: .insufficientEvidence) }
        let localEstimate = RoutingEstimate(seconds: local.seconds, deviation: local.deviation, sampleCount: local.count)
        let cloudEstimate = RoutingEstimate(seconds: cloud.seconds, deviation: cloud.deviation, sampleCount: cloud.count)
        if now.timeIntervalSince(cloud.latest) >= configuration.cloudRetryInterval {
            return .init(route: .cloud, reason: .cloudRefresh, localEstimate: localEstimate, cloudEstimate: cloudEstimate)
        }
        let saving = cloud.seconds - local.seconds
            - configuration.variabilityAllowance * (cloud.deviation + local.deviation)
        let useLocal = saving >= max(configuration.minimumLocalSavingSeconds,
            cloud.seconds * configuration.minimumLocalSavingFraction)
        return .init(route: useLocal ? .onDevice : .cloud, reason: useLocal ? .localFaster : .cloudPreferred,
            localEstimate: localEstimate, cloudEstimate: cloudEstimate)
    }

    /// Bounds each provider's history independently so frequent cloud calls cannot evict local calibration.
    public mutating func record(
        model: InferenceRoute, tokens: Int, seconds: Double,
        connection: Connection, now: Date, workload: RoutingWorkload = .init(),
        configuration: RoutingConfiguration = .balanced
    ) {
        guard tokens > 0, seconds.isFinite, seconds > 0 else { return }
        samples.removeAll { now.timeIntervalSince($0.date) < 0 || now.timeIntervalSince($0.date) > configuration.sampleLifetime }
        samples.append(Sample(model: model, tokens: tokens, seconds: seconds, connection: connection, date: now, workload: workload))
        var excess = samples.lazy.filter { $0.model == model }.count - 128
        samples.removeAll { sample in
            guard excess > 0, sample.model == model else { return false }
            excess -= 1
            return true
        }
        failures.removeAll { $0.model == model && (model == .onDevice || $0.connection == connection) }
        failures.removeAll { now.timeIntervalSince($0.date) > configuration.failureBackoff }
    }

    /// Applies a short cooldown after a model failure, cloud unavailability or quota exhaustion.
    public mutating func recordFailure(
        model: InferenceRoute = .cloud, connection: Connection, now: Date, configuration: RoutingConfiguration = .balanced
    ) {
        failures.removeAll {
            ($0.model == model && (model == .onDevice || $0.connection == connection))
                || now.timeIntervalSince($0.date) > configuration.failureBackoff
        }
        failures.append(Failure(model: model, connection: connection, date: now))
        failures = Array(failures.suffix(16))
    }

    /// Discards old cloud assumptions when the observed network path changes.
    public mutating func changedConnection(_ connection: Connection) {
        samples.removeAll { $0.model == .cloud && $0.connection == connection }
        failures.removeAll { $0.model == .cloud && $0.connection == connection }
    }

    /// Estimates weighted latency and spread; overlapping one-deviation ranges retain cloud preference.
    private func estimate(
        _ samples: [Sample], configuration: RoutingConfiguration
    ) -> (seconds: Double, deviation: Double, count: Int, latest: Date)? {
        let nearby = samples.prefix(configuration.predictionSampleLimit)
        guard nearby.count >= configuration.minimumSamples, let latest = nearby.first?.date else { return nil }
        var total = 0.0
        var weights = 0.0
        for (index, sample) in nearby.enumerated() {
            let weight = pow(0.5, Double(index))
            total += sample.seconds * weight
            weights += weight
        }
        let mean = total / weights
        let variance = nearby.enumerated().reduce(0.0) { result, entry in
            let difference = entry.element.seconds - mean
            return result + pow(0.5, Double(entry.offset)) * difference * difference
        } / weights
        return (mean, sqrt(variance), nearby.count, latest)
    }

    /// Finds only recent, similarly sized observations, newest first.
    private func comparable(
        _ model: InferenceRoute, tokens: Int, workload: RoutingWorkload, connection: Connection, now: Date,
        configuration: RoutingConfiguration
    ) -> [Sample] {
        guard tokens > 0 else { return [] }
        return samples.filter {
            let age = now.timeIntervalSince($0.date)
            let ratio = Double($0.tokens) / Double(tokens)
            return $0.model == model && (model == .onDevice || $0.connection == connection)
                && workload.isComparable(to: $0.workload ?? .init(), model: model, tolerance: configuration.sizeTolerance)
                && age >= 0 && age <= configuration.sampleLifetime && ((1 - configuration.sizeTolerance)...(1 + configuration.sizeTolerance)).contains(ratio)
        }.sorted { $0.date > $1.date }
    }
}
