import Foundation
import Network
import OSLog

/// Describes admission of a connection observation without exposing native network identities.
struct RoutingConnectionObservation: Sendable {
    /// Separates a real transition, an exact native duplicate and an out-of-order observation.
    enum Disposition: String, Sendable { case applied, duplicate, stale }
    let source: String
    let disposition: Disposition
    let observedAt: ContinuousClock.Instant
    let previousConnection: PerformanceProfile.Connection
    let connection: PerformanceProfile.Connection
    let generationBefore: Int
    let generationAfter: Int
    let nativeEqual: Bool?
    let nativeChanges: [String: Bool]

    /// Rejects reordered observations first; only full native equality can suppress invalidation.
    static func disposition(last: ContinuousClock.Instant?, observedAt: ContinuousClock.Instant,
        nativeEqual: Bool?) -> Disposition {
        if let last, observedAt < last { return .stale }
        return nativeEqual == true ? .duplicate : .applied
    }

    /// Distinguishes observable route/cost transitions from opaque state or link-quality reassessment.
    /// Opaque inequalities still invalidate in-flight work; historical timings remain priors for revalidation.
    static func shouldDiscardCloudHistory(previous: PerformanceProfile.Connection,
        current: PerformanceProfile.Connection, native: Bool, changes: [String: Bool]) -> Bool {
        guard previous.kind != .unknown else { return false }
        if !native || previous != current { return true }
        return changes.contains { key, changed in changed && key != "linkQuality" }
    }

    /// Emits only change flags and history handling, never network addresses or interface identities.
    func log(discardedHistory: Bool, cloudSamples: Int) {
        let logger = Logger(subsystem: "AdaptiveModelRouting", category: "ConnectionObservation")
        let changed = nativeChanges.filter { $0.value }.map(\.key).sorted().joined(separator: ",")
        logger.debug("connection source=\(source, privacy: .public) disposition=\(disposition.rawValue, privacy: .public) generation=\(generationBefore, privacy: .public)->\(generationAfter, privacy: .public) nativeEqual=\(String(describing: nativeEqual), privacy: .public) changed=\(changed, privacy: .public) historyDiscarded=\(discardedHistory, privacy: .public) cloudSamples=\(cloudSamples, privacy: .public)")
    }

    /// Converts native readiness and cost flags into the existing coarse, persistable connection value.
    static func connection(for path: NWPath) -> PerformanceProfile.Connection {
        let kind: PerformanceProfile.Connection.Kind
        if path.status == .unsatisfied { kind = .offline }
        else if path.usesInterfaceType(.wifi) { kind = .wifi }
        else if path.usesInterfaceType(.cellular) { kind = .cellular }
        else if path.usesInterfaceType(.wiredEthernet) { kind = .wired }
        else { kind = .other }
        return .init(kind: kind, expensive: path.isExpensive, constrained: path.isConstrained)
    }

    /// Compares in-memory native values but returns only change flags, never their addresses or identifiers.
    static func changes(from previous: NWPath?, to path: NWPath?) -> [String: Bool] {
        guard let previous, let path else { return [:] }
        let types: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .loopback, .other]
        let gatewaysEqual = previous.gateways.allSatisfy { path.gateways.contains($0) }
            && path.gateways.allSatisfy { previous.gateways.contains($0) }
        return [
            "status": previous.status != path.status,
            "availableInterfaceSet": Set(previous.availableInterfaces.map(\.index)) != Set(path.availableInterfaces.map(\.index)),
            "usedInterfaceTypes": types.map { previous.usesInterfaceType($0) } != types.map { path.usesInterfaceType($0) },
            "gatewaySet": !gatewaysEqual,
            "supportsIPv4": previous.supportsIPv4 != path.supportsIPv4,
            "supportsIPv6": previous.supportsIPv6 != path.supportsIPv6,
            "supportsDNS": previous.supportsDNS != path.supportsDNS,
            "linkQuality": previous.linkQuality != path.linkQuality,
            "expensive": previous.isExpensive != path.isExpensive,
            "constrained": previous.isConstrained != path.isConstrained,
            "ultraConstrained": previous.isUltraConstrained != path.isUltraConstrained,
            "localEndpoint": previous.localEndpoint != path.localEndpoint,
            "remoteEndpoint": previous.remoteEndpoint != path.remoteEndpoint,
        ]
    }
}
