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

    private static let lifetime: TimeInterval = 7 * 86_400
    private static let retryInterval: TimeInterval = 10 * 60
    private static let localRefreshInterval: TimeInterval = 30 * 60
    private static let failureBackoff: TimeInterval = 60

    /// Prefers PCC for quality unless trustworthy local timings show a substantial advantage.
    public func choose(
        inputTokens: Int, localCapacity: Int, connection: Connection, now: Date,
        configuration: RoutingConfiguration = .init(),
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init()
    ) -> InferenceRoute {
        if policy == .cloudRequired { return .cloud }
        if connection.kind == .offline || failures.contains(where: {
            $0.model == .cloud && $0.connection == connection && now.timeIntervalSince($0.date) >= 0
                && now.timeIntervalSince($0.date) < Self.failureBackoff
        }) { return .onDevice }
        guard InferenceExecutor.fitsLocal(inputTokens: inputTokens, localCapacity: localCapacity,
            responseReserve: max(configuration.localResponseReserve, workload.expectedOutputTokens ?? 0)) else { return .cloud }
        if failures.contains(where: {
            $0.model == .onDevice && now.timeIntervalSince($0.date) >= 0
                && now.timeIntervalSince($0.date) < Self.failureBackoff
        }) { return .cloud }
        let localSamples = comparable(.onDevice, tokens: inputTokens, workload: workload, connection: connection, now: now)
        let cloudSamples = comparable(.cloud, tokens: inputTokens, workload: workload, connection: connection, now: now)
        let lastLocal = localSamples.first?.date ?? .distantPast
        // Select one local request after three cloud requests, without duplicating a transcript.
        if (localSamples.count < 3 || now.timeIntervalSince(lastLocal) >= Self.localRefreshInterval),
           cloudSamples.filter({ $0.date > lastLocal }).count >= 3 { return .onDevice }
        guard
              let local = estimate(.onDevice, tokens: inputTokens, workload: workload, connection: connection, now: now),
              let cloud = estimate(.cloud, tokens: inputTokens, workload: workload, connection: connection, now: now) else { return .cloud }
        // Retry the preferred quality model occasionally rather than freezing on old cloud timings.
        guard now.timeIntervalSince(cloud.latest) < Self.retryInterval else { return .cloud }
        let conservativeSaving = cloud.seconds - cloud.deviation - local.seconds - local.deviation
        return conservativeSaving >= max(configuration.minimumLocalSavingSeconds,
            cloud.seconds * configuration.minimumLocalSavingFraction) ? .onDevice : .cloud
    }

    /// Records valid completed requests and bounds the local cache to recent metadata.
    public mutating func record(
        model: InferenceRoute, tokens: Int, seconds: Double,
        connection: Connection, now: Date, workload: RoutingWorkload = .init()
    ) {
        guard tokens > 0, seconds.isFinite, seconds > 0 else { return }
        samples.removeAll { now.timeIntervalSince($0.date) < 0 || now.timeIntervalSince($0.date) > Self.lifetime }
        samples.append(Sample(model: model, tokens: tokens, seconds: seconds, connection: connection, date: now, workload: workload))
        samples = Array(samples.suffix(128))
        failures.removeAll { $0.model == model && (model == .onDevice || $0.connection == connection) }
        failures.removeAll { now.timeIntervalSince($0.date) > Self.failureBackoff }
    }

    /// Applies a short cooldown after a model failure, cloud unavailability or quota exhaustion.
    public mutating func recordFailure(
        model: InferenceRoute = .cloud, connection: Connection, now: Date
    ) {
        failures.removeAll {
            ($0.model == model && (model == .onDevice || $0.connection == connection))
                || now.timeIntervalSince($0.date) > Self.failureBackoff
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
        _ model: InferenceRoute, tokens: Int, workload: RoutingWorkload, connection: Connection, now: Date
    ) -> (seconds: Double, deviation: Double, latest: Date)? {
        let nearby = comparable(model, tokens: tokens, workload: workload, connection: connection, now: now).prefix(6)
        guard nearby.count >= 3, let latest = nearby.first?.date else { return nil }
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
        return (mean, sqrt(variance), latest)
    }

    /// Finds only recent, similarly sized observations, newest first.
    private func comparable(
        _ model: InferenceRoute, tokens: Int, workload: RoutingWorkload, connection: Connection, now: Date
    ) -> [Sample] {
        guard tokens > 0 else { return [] }
        return samples.filter {
            let age = now.timeIntervalSince($0.date)
            let ratio = Double($0.tokens) / Double(tokens)
            return $0.model == model && (model == .onDevice || $0.connection == connection)
                && workload.isComparable(to: $0.workload ?? .init(), model: model)
                && age >= 0 && age <= Self.lifetime && (0.75...1.25).contains(ratio)
        }.sorted { $0.date > $1.date }
    }
}
