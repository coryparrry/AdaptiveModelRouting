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
        /// Matches successful lanes from one real request without storing its content.
        let comparisonID: UUID?
        /// Retains matched local latency even after frequent local work evicts the original sample.
        var localComparisonSeconds: Double?
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
        configuration: RoutingConfiguration = .fastest,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init(), lastCloudUse: Date? = nil
    ) -> InferenceRoute {
        decision(inputTokens: inputTokens, localCapacity: localCapacity, connection: connection,
            now: now, configuration: configuration, policy: policy, workload: workload, lastCloudUse: lastCloudUse).route
    }

    /// Explains request constraints, availability, health, calibration and predicted-latency decisions.
    public func decision(
        inputTokens: Int, localCapacity: Int, connection: Connection, now: Date,
        configuration: RoutingConfiguration = .fastest, policy: RoutingPolicy = .automatic,
        workload: RoutingWorkload = .init(), availability: RoutingAvailability = .init(), lastCloudUse: Date? = nil
    ) -> RoutingDecision {
        executionDecision(inputTokens: inputTokens, localCapacity: localCapacity, connection: connection, now: now,
            configuration: configuration, policy: policy, workload: workload, availability: availability,
            lastCloudUse: lastCloudUse, lastLocalLearning: nil)
    }

    /// Includes owner-managed local learning permission without changing the standalone prediction contract.
    func executionDecision(inputTokens: Int, localCapacity: Int, connection: Connection, now: Date,
        configuration: RoutingConfiguration, policy: RoutingPolicy, workload: RoutingWorkload,
        availability: RoutingAvailability, lastCloudUse: Date?, lastLocalLearning: Date?
    ) -> RoutingDecision {
        let availability = availability.restricted(to: policy, conserveQuota: configuration.conserveCloudQuota)
        if policy == .cloudRequired { return .init(route: .cloud, reason: .cloudRequired) }
        if policy == .localOnly { return .init(route: .onDevice, reason: .localOnly) }
        if !availability.onDevice && !availability.cloud { return .init(route: .cloud, reason: .noAvailableProvider) }
        if connection.kind == .offline { return .init(route: .onDevice, reason: .offline) }
        if !availability.onDevice { return .init(route: .cloud, reason: .localUnavailable) }
        if !availability.cloud {
            return .init(route: .onDevice,
                reason: availability.cloudQuota.blocksCloud(for: policy, conserveQuota: configuration.conserveCloudQuota)
                    ? .cloudQuotaConserved : .cloudUnavailable)
        }
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
        if configuration.calibration == .singleProvider,
           (localSamples.count < configuration.minimumSamples
            || now.timeIntervalSince(lastLocal) >= configuration.localRefreshInterval),
           cloudSamples.filter({ $0.date > lastLocal }).count >= configuration.minimumSamples {
            return .init(route: .onDevice, reason: .localCalibration)
        }
        guard let local = estimate(localSamples, configuration: configuration)
            else { return .init(route: .cloud, reason: .insufficientEvidence) }
        let localEstimate = RoutingEstimate(seconds: local.seconds, deviation: local.deviation, sampleCount: local.count)
        guard let cloud = estimate(cloudSamples, configuration: configuration) else {
            // A successful faster observation permits one foreground learning attempt. Its owner consumes
            // that proof before yielding; unsuccessful attempts cannot authorize repeated paid learning.
            var route: InferenceRoute = .cloud
            if case .paired = configuration.calibration {
                route = .onDevice
                if let latest = cloudSamples.first, let latestLocal = localSamples.first, let lastCloudUse,
                   latest.date >= lastCloudUse,
                   latest.seconds < min(local.seconds, latestLocal.seconds) { route = .cloud }
            }
            return .init(route: route, reason: .insufficientEvidence, localEstimate: localEstimate)
        }
        let cloudEstimate = RoutingEstimate(seconds: cloud.seconds, deviation: cloud.deviation, sampleCount: cloud.count)
        if configuration.calibration == .singleProvider,
           now.timeIntervalSince(max(cloud.latest, lastCloudUse ?? cloud.latest)) >= configuration.cloudRetryInterval {
            return .init(route: .cloud, reason: .cloudRefresh, localEstimate: localEstimate, cloudEstimate: cloudEstimate)
        }
        let saving = cloud.seconds - local.seconds
            - configuration.variabilityAllowance * (cloud.deviation + local.deviation)
        let useLocal = local.seconds < cloud.seconds && saving >= max(configuration.minimumLocalSavingSeconds,
            cloud.seconds * configuration.minimumLocalSavingFraction)
        if !useLocal, case .paired = configuration.calibration,
           configuration.minimumLocalSavingSeconds == 0, configuration.minimumLocalSavingFraction == 0,
           configuration.variabilityAllowance == 0, let lastLocalLearning, let latest = localSamples.first,
           let latestCloud = cloudSamples.first, latest.date >= lastLocalLearning,
           latest.seconds < min(cloud.seconds, latestCloud.seconds) {
            return .init(route: .onDevice, reason: .localCalibration,
                localEstimate: localEstimate, cloudEstimate: cloudEstimate)
        }
        if !useLocal, needsLocalConfirmation(localSamples: localSamples, latestCloud: cloudSamples.first,
            tokens: inputTokens, workload: workload, connection: connection, now: now, configuration: configuration) {
            return .init(route: .onDevice, reason: .localCalibration,
                localEstimate: localEstimate, cloudEstimate: cloudEstimate)
        }
        return .init(route: useLocal ? .onDevice : .cloud, reason: useLocal ? .localFaster : .cloudPreferred,
            localEstimate: localEstimate, cloudEstimate: cloudEstimate)
    }

    /// Confirms a paid promotion when recent matched comparisons disagree with a local latency spike.
    private func needsLocalConfirmation(localSamples: [Sample], latestCloud: Sample?, tokens: Int,
        workload: RoutingWorkload, connection: Connection, now: Date, configuration: RoutingConfiguration
    ) -> Bool {
        guard configuration.conserveCloudQuota, case .paired = configuration.calibration,
              configuration.minimumLocalSavingSeconds == 0, configuration.minimumLocalSavingFraction == 0,
              configuration.variabilityAllowance == 0, !localSamples.isEmpty,
              let cloud = latestCloud else { return false }
        let recent = localSamples.prefix(configuration.minimumSamples)
        if recent.count == configuration.minimumSamples && recent.allSatisfy({ $0.seconds > cloud.seconds }) {
            return false
        }
        let comparisons = comparable(.cloud, tokens: tokens, workload: workload, connection: connection,
            now: now, configuration: configuration, limit: 2) { sample in
            sample.comparisonID != nil && sample.localComparisonSeconds.map { $0.isFinite && $0 > 0 } == true
                && workload.isComparable(to: sample.workload ?? .init(), model: .onDevice,
                    tolerance: configuration.sizeTolerance)
        }
        return comparisons.contains { $0.localComparisonSeconds! < $0.seconds }
    }

    /// Returns nil for ineligible requests, true for missing/stale evidence and false for cadence-only probes.
    func needsCalibration(inputTokens: Int, localCapacity: Int, connection: Connection, now: Date,
        configuration: RoutingConfiguration, policy: RoutingPolicy, workload: RoutingWorkload,
        availability: RoutingAvailability, decision: RoutingDecision
    ) -> Bool? {
        guard case .paired = configuration.calibration, policy == .automatic,
              inputTokens > 0, availability.onDevice, availability.cloud,
              connection.kind != .offline,
              (decision.route == .cloud || availability.permitsCloudCalibration),
              InferenceExecutor.fitsLocal(inputTokens: inputTokens, localCapacity: localCapacity,
                  responseReserve: max(configuration.localResponseReserve, workload.expectedOutputTokens ?? 0)),
              !failures.contains(where: {
                  ($0.model == .onDevice || $0.connection == connection)
                      && now.timeIntervalSince($0.date) >= 0
                      && now.timeIntervalSince($0.date) < configuration.failureBackoff
              }) else { return nil }
        let other: InferenceRoute = decision.route == .cloud ? .onDevice : .cloud
        let samples = comparable(other, tokens: inputTokens, workload: workload, connection: connection,
            now: now, configuration: configuration)
        let interval = other == .cloud ? configuration.cloudRetryInterval : configuration.localRefreshInterval
        return samples.count < configuration.minimumSamples
            || (samples.first.map { now.timeIntervalSince($0.date) >= interval } ?? true)
    }

    /// Bounds each provider's history independently so frequent cloud calls cannot evict local calibration.
    public mutating func record(
        model: InferenceRoute, tokens: Int, seconds: Double,
        connection: Connection, now: Date, workload: RoutingWorkload = .init(),
        configuration: RoutingConfiguration = .fastest
    ) {
        record(model: model, tokens: tokens, seconds: seconds, connection: connection, now: now,
            workload: workload, configuration: configuration, comparisonID: nil)
    }

    /// Records matched successful lanes in either completion order, retaining the comparison on the cloud sample.
    mutating func record(model: InferenceRoute, tokens: Int, seconds: Double, connection: Connection,
        now: Date, workload: RoutingWorkload, configuration: RoutingConfiguration, comparisonID: UUID?
    ) {
        guard seconds.isFinite, seconds > 0, tokens >= 0 else { return }
        failures.removeAll { $0.model == model && (model == .onDevice || $0.connection == connection) }
        failures.removeAll { now.timeIntervalSince($0.date) > configuration.failureBackoff }
        guard tokens > 0 else { return }
        samples.removeAll { now.timeIntervalSince($0.date) < 0 || now.timeIntervalSince($0.date) > configuration.sampleLifetime }
        let matched = comparisonID.flatMap { id in samples.lastIndex { $0.comparisonID == id && $0.model != model } }
        let localSeconds = model == .cloud ? matched.map { samples[$0].seconds } : nil
        if model == .onDevice, let matched { samples[matched].localComparisonSeconds = seconds }
        samples.append(Sample(model: model, tokens: tokens, seconds: seconds, connection: connection,
            date: now, workload: workload, comparisonID: comparisonID, localComparisonSeconds: localSeconds))
        trimSamples(for: model)
    }

    /// Enforces the per-provider limit without changing relative order or a sample's paired metadata.
    private mutating func trimSamples(for model: InferenceRoute) {
        var excess = samples.lazy.filter { $0.model == model }.count - 128
        samples.removeAll { sample in
            guard excess > 0, sample.model == model else { return false }
            excess -= 1
            return true
        }
    }

    /// Applies a short cooldown after a model failure, cloud unavailability or quota exhaustion.
    public mutating func recordFailure(
        model: InferenceRoute = .cloud, connection: Connection, now: Date, configuration: RoutingConfiguration = .fastest
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

    /// Tracks invalidations whose older samples or failures are still inside a temporarily inaccessible cache.
    final class CacheRecovery {
        private(set) var invalidatedPaths: [Connection] = []
        private var recoveredCloudPaths: [Connection] = []
        private var recoveredLocal = false

        /// Records each materially changed cloud path at most once until its history can be read.
        func invalidate(_ connection: Connection) {
            if !invalidatedPaths.contains(connection) { invalidatedPaths.append(connection) }
        }

        /// Remembers cleared health even when a successful call had no tokens eligible for timing.
        func recordSuccess(_ model: InferenceRoute, connection: Connection) {
            if model == .onDevice { recoveredLocal = true }
            else if !recoveredCloudPaths.contains(connection) { recoveredCloudPaths.append(connection) }
        }

        /// Selecting the first explicit model discards health learned from the previous anonymous workload.
        func clearWorkloadHealth() {
            recoveredLocal = false
            recoveredCloudPaths.removeAll()
        }

        /// Distinguishes a pristine restore from newer changes that still need a successful save.
        var hasChanges: Bool { recoveredLocal || !recoveredCloudPaths.isEmpty || !invalidatedPaths.isEmpty }

        /// Prevents old failures from superseding a success on the same provider since startup.
        func cleared(_ failure: Failure) -> Bool {
            failure.model == .onDevice ? recoveredLocal : recoveredCloudPaths.contains(failure.connection)
        }
    }

    /// Restores saved history underneath live observations, retaining matched pairs and newer health outcomes.
    mutating func restorePrior(_ saved: Self, recovery: CacheRecovery, configuration: RoutingConfiguration) {
        var combined = saved
        for connection in recovery.invalidatedPaths { combined.changedConnection(connection) }
        combined.failures.removeAll(where: recovery.cleared)
        combined.samples.append(contentsOf: samples)
        combined.trimSamples(for: .onDevice)
        combined.trimSamples(for: .cloud)
        for failure in failures {
            combined.recordFailure(model: failure.model, connection: failure.connection,
                now: failure.date, configuration: configuration)
        }
        self = combined
    }

    /// Estimates weighted latency and spread; configured presets decide whether spread affects selection.
    private func estimate(
        _ samples: [Sample], configuration: RoutingConfiguration
    ) -> (seconds: Double, deviation: Double, count: Int, latest: Date)? {
        let nearby = samples.prefix(configuration.predictionSampleLimit)
        guard nearby.count >= configuration.minimumSamples, let latest = nearby.first?.date else { return nil }
        let weighted = nearby.enumerated().map { index, sample in
            (sample.seconds, exp2(-Double(index) - max(0, latest.timeIntervalSince(sample.date)) / configuration.predictionHalfLife))
        }
        let weights = weighted.reduce(0) { $0 + $1.1 }
        let mean = weighted.reduce(0) { $0 + $1.0 * $1.1 } / weights
        let variance = weighted.reduce(0) { result, entry in
            let difference = entry.0 - mean
            return result + entry.1 * difference * difference
        } / weights
        return (mean, sqrt(variance), nearby.count, latest)
    }

    /// Finds only recent, similarly sized observations, newest first.
    private func comparable(
        _ model: InferenceRoute, tokens: Int, workload: RoutingWorkload, connection: Connection, now: Date,
        configuration: RoutingConfiguration, limit: Int? = nil, including: (Sample) -> Bool = { _ in true }
    ) -> [Sample] {
        guard tokens > 0 else { return [] }
        /// Applies the same size, session, age and path contract to both bounded and full-window selection.
        func matches(_ sample: Sample) -> Bool {
            let age = now.timeIntervalSince(sample.date)
            let ratio = Double(sample.tokens) / Double(tokens)
            return sample.model == model && including(sample) && (model == .onDevice || sample.connection == connection)
                && workload.isComparable(to: sample.workload ?? .init(), model: model, tolerance: configuration.sizeTolerance)
                && age >= 0 && age <= configuration.sampleLifetime && ((1 - configuration.sizeTolerance)...(1 + configuration.sizeTolerance)).contains(ratio)
        }
        let limit = limit ?? configuration.predictionSampleLimit
        if limit > 16 { return Array(samples.filter(matches).sorted { $0.date > $1.date }.prefix(limit)) }
        var nearby: [(index: Int, sample: Sample)] = []
        nearby.reserveCapacity(limit)
        for (index, sample) in samples.enumerated().reversed() where sample.model == model {
            if nearby.count == limit, let oldest = nearby.last, sample.date < oldest.sample.date { continue }
            guard matches(sample) else { continue }
            let insertion = nearby.firstIndex {
                $0.sample.date < sample.date || ($0.sample.date == sample.date && $0.index > index)
            } ?? nearby.count
            if insertion < limit {
                nearby.insert((index, sample), at: insertion)
                if nearby.count > limit { nearby.removeLast() }
            }
        }
        return nearby.map(\.sample)
    }
}
