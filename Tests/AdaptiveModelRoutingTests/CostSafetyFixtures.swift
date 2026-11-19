import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Supplies provider-independent success and failure contracts for exhaustive dispatch checks.
enum CostOutcome: String, CaseIterable {
    case success, unavailable, transient, permanent, cancelled
}

/// Represents independent calibration histories without relying on wall-clock inference performance.
enum CostTraining: String, CaseIterable { case cold, localFaster, cloudFaster }

/// Identifies the route and error class rather than inspecting unstable provider error descriptions.
enum CostProviderError: Error, Equatable {
    case transient(InferenceRoute), permanent(InferenceRoute)
}

/// Describes one combination of public request policy, readiness, size, connection and provider results.
struct CostScenario {
    let policy: RoutingPolicy
    let paired: Bool
    let training: CostTraining
    let localReady: Bool
    let cloudReady: Bool
    let offline: Bool
    let capacity: Int
    let cloud: CostOutcome
    let local: CostOutcome
    var localAllowed: Bool { localReady && capacity >= 500 }
    var label: String {
        "policy=\(policy),paired=\(paired),training=\(training.rawValue),ready=\(localReady)/\(cloudReady),offline=\(offline),capacity=\(capacity),cloud=\(cloud.rawValue),local=\(local.rawValue)"
    }

    /// Enumerates each declared dimension once, with separate at-capacity and overflowing requests.
    static func all() -> [Self] {
        var values: [Self] = []
        for policy in [RoutingPolicy.automatic, .localOnly, .cloudRequired] {
            for paired in [false, true] {
                for training in CostTraining.allCases {
                    for localReady in [false, true] {
                        for cloudReady in [false, true] {
                            for offline in [false, true] {
                                for capacity in [8_192, 500, 499] {
                                    for cloud in CostOutcome.allCases {
                                        for local in CostOutcome.allCases where local != .unavailable {
                                            values.append(.init(policy: policy, paired: paired, training: training,
                                                localReady: localReady, cloudReady: cloudReady, offline: offline,
                                                capacity: capacity, cloud: cloud, local: local))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return values
    }

    /// States the foreground selection contract independently of the router's decision implementation.
    var preferred: InferenceRoute? {
        switch policy {
        case .localOnly: return localAllowed ? .onDevice : nil
        case .cloudRequired: return cloudReady ? .cloud : nil
        case .automatic:
            if offline { return localAllowed ? .onDevice : nil }
            if !localReady { return cloudReady ? .cloud : nil }
            if !cloudReady { return localAllowed ? .onDevice : nil }
            if !localAllowed { return .cloud }
            return training == .localFaster ? .onDevice : .cloud
        }
    }

    /// Defines value/error expectations from the public policy and recoverable-failure contract.
    var expected: String {
        guard let preferred else { return "none" }
        if preferred == .onDevice {
            if local == .success { return "value.onDevice" }
            if local == .cancelled { return "cancelled" }
            if local == .permanent || policy == .localOnly { return "\(local.rawValue).onDevice" }
            return cloudReady ? terminal(cloud, route: .cloud) : "transient.onDevice"
        }
        if cloud == .success { return "value.cloud" }
        if cloud == .cancelled { return "cancelled" }
        if cloud == .permanent { return "permanent.cloud" }
        if policy != .automatic || !localAllowed {
            return cloud == .unavailable ? "none" : "transient.cloud"
        }
        return terminal(local, route: .onDevice)
    }

    /// Enumerates authorized calls, including only due cold-start probes and policy-permitted recovery.
    var permittedCalls: Set<InferenceRoute> {
        guard let preferred else { return [] }
        var calls: Set<InferenceRoute> = [preferred]
        if preferred == .onDevice && local == .transient && policy == .automatic && cloudReady { calls.insert(.cloud) }
        if preferred == .cloud && (cloud == .transient || cloud == .unavailable)
            && policy == .automatic && localAllowed { calls.insert(.onDevice) }
        if paired && policy == .automatic && (training == .cold || preferred == .cloud) && localAllowed && cloudReady && !offline {
            calls.insert(.cloud)
            calls.insert(.onDevice)
        }
        return calls
    }

    /// Requires the foreground and any necessary recovery call; healthy cold pairs also require the planned probe.
    var requiredCalls: Set<InferenceRoute> {
        guard let preferred else { return [] }
        if preferred == .cloud && (cloud == .permanent || cloud == .cancelled) { return [.cloud] }
        return permittedCalls
    }

    /// Maps a final provider outcome without permitting a third invocation or second fallback.
    private func terminal(_ outcome: CostOutcome, route: InferenceRoute) -> String {
        switch outcome {
        case .success: "value.\(route.rawValue)"
        case .unavailable: "none"
        case .cancelled: "cancelled"
        case .transient, .permanent: "\(outcome.rawValue).\(route.rawValue)"
        }
    }
}

/// Counts dispatch and producer start separately so cancelled-before-start work cannot hide duplicates.
@MainActor
final class CostCalls {
    var dispatched: [InferenceRoute: Int] = [:]
    var started: [InferenceRoute: Int] = [:]
    var classified: [InferenceRoute: Int] = [:]

    /// Executes one synthetic provider operation and preserves nil/cancellation/error distinctions.
    func generate(_ route: InferenceRoute, outcome: CostOutcome) throws -> String? {
        started[route, default: 0] += 1
        switch outcome {
        case .success: return route.rawValue
        case .unavailable: return nil
        case .transient: throw CostProviderError.transient(route)
        case .permanent: throw CostProviderError.permanent(route)
        case .cancelled: throw CancellationError()
        }
    }

    /// Retries only explicitly recoverable synthetic errors and records classification multiplicity.
    func classify(_ route: InferenceRoute, error: any Error) -> Bool {
        classified[route, default: 0] += 1
        if let error = error as? CostProviderError, case .transient = error { return true }
        return false
    }

    /// Creates a tracked producer that can finish empty or fail without publishing a partial value.
    func stream(_ route: InferenceRoute, outcome: CostOutcome) -> RoutingProviderStream<String> {
        dispatched[route, default: 0] += 1
        return RoutingProviderStream { continuation in
            if let value = try self.generate(route, outcome: outcome) { continuation.yield(value) }
        }
    }
}

/// Loads immutable calibrated fixtures, then disables writes so matrix cases cannot train one another.
@MainActor
final class CostProfiles {
    private let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let system = "cost-safety-test"
    let workload = RoutingWorkload(expectedOutputTokens: 128)

    /// Creates cold/local-winning/cloud-winning fixtures through the supported Codable cache format.
    init(cloudAge: TimeInterval = 0) throws {
        let now = Date.now
        for training in CostTraining.allCases {
            var profile = PerformanceProfile()
            if training != .cold {
                for index in 0..<3 {
                    let date = now.addingTimeInterval(Double(index - 3))
                    for route in [InferenceRoute.cloud, .onDevice] {
                        let fast = (training == .localFaster) == (route == .onDevice)
                        profile.record(model: route, tokens: 100, seconds: fast ? 0.001 : 1,
                            connection: .init(kind: .wifi), now: date, workload: workload)
                    }
                }
            }
            let directory = root.appendingPathComponent(training.rawValue)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
            var observations = encoded["samples"] as! [[String: Any]]
            for index in observations.indices where observations[index]["model"] as? String == "cloud" {
                observations[index]["date"] = (observations[index]["date"] as! Double) - cloudAge
            }
            encoded["samples"] = observations
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "system": system, "profile": encoded])
            try data.write(to: directory.appendingPathComponent("latency.json"))
        }
    }

    /// Creates independent routing state with identical workload-size and connection calibration inputs.
    func router(_ scenario: CostScenario, configuration: RoutingConfiguration? = nil) throws -> AdaptiveRouter {
        let router = AdaptiveRouter(directory: root.appendingPathComponent(scenario.training.rawValue),
            system: system, monitorConnection: false,
            configuration: configuration ?? .init(calibration: scenario.paired ? .paired() : .singleProvider))
        try router.setPersistence(.memoryOnly, clearExistingCache: false)
        router.updateConnection(.init(kind: scenario.offline ? .offline : .wifi))
        return router
    }

    /// Removes only the immutable fixture directories owned by this test run.
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Normalizes thrown errors for independently specified matrix expectations.
func costError(_ error: any Error) -> String {
    if error is CancellationError { return "cancelled" }
    guard let error = error as? CostProviderError else { return "unexpected.\(String(reflecting: type(of: error)))" }
    switch error {
    case .transient(let route): return "transient.\(route.rawValue)"
    case .permanent(let route): return "permanent.\(route.rawValue)"
    }
}
