import Foundation
import Network
import XCTest
@testable import AdaptiveModelRouting

/// Replays native snapshot admission without model calls, location access or a live network dependency.
@MainActor
final class ConnectionObservationTests: XCTestCase {
    /// Only equal full native snapshots are duplicates; unknown/manual and unequal native paths apply.
    func testAdmissionMatrixPreservesUnequalSameCoarseTransitions() {
        let now = ContinuousClock.now
        for same in [Bool?.none, .some(false), .some(true)] {
            XCTAssertEqual(RoutingConnectionObservation.disposition(last: now, observedAt: now.advanced(by: .seconds(-1)),
                nativeEqual: same), .stale)
            XCTAssertEqual(RoutingConnectionObservation.disposition(last: now, observedAt: now,
                nativeEqual: same), same == true ? .duplicate : .applied)
            XCTAssertEqual(RoutingConnectionObservation.disposition(last: now, observedAt: now.advanced(by: .seconds(1)),
                nativeEqual: same), same == true ? .duplicate : .applied)
        }
        XCTAssertEqual(RoutingConnectionObservation.disposition(last: nil, observedAt: now, nativeEqual: nil), .applied)
    }

    /// Replaying an actual equal native snapshot retains cloud history and the request generation.
    func testExactNativeDuplicatePreservesHistory() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let path = NWPathMonitor().currentPath
        var events: [RoutingConnectionObservation] = []
        router.onConnectionObservation = { events.append($0) }
        let now = ContinuousClock.now
        router.receiveNativePath(path, observedAt: now)
        let generation = router.snapshot().generation
        _ = try await router.measure(model: .cloud, inputTokens: 100, snapshot: router.snapshot()) { "native fixture" }
        XCTAssertEqual(router.profile.samples.count, 1)
        router.receiveNativePath(path, observedAt: now.advanced(by: .seconds(1)))
        XCTAssertEqual(router.snapshot().generation, generation)
        XCTAssertEqual(router.profile.samples.count, 1)
        XCTAssertEqual(events.map(\.disposition), [.applied, .duplicate])
        XCTAssertEqual(events.last?.nativeEqual, true)
        XCTAssertEqual(events.last?.source, "native")
        XCTAssertTrue(events.last!.nativeChanges.values.allSatisfy { !$0 })
    }

    /// A duplicate delivered during provider work cannot invalidate that work's admitted timing.
    func testDuplicateDuringMeasurementDoesNotDiscardTiming() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let path = NWPathMonitor().currentPath
        let now = ContinuousClock.now
        router.receiveNativePath(path, observedAt: now)
        let snapshot = router.snapshot()
        let value = try await router.measure(model: .cloud, inputTokens: 100, snapshot: snapshot) {
            router.receiveNativePath(path, observedAt: now.advanced(by: .seconds(1)))
            return "real operation stand-in"
        }
        XCTAssertEqual(value, "real operation stand-in")
        XCTAssertEqual(router.snapshot().generation, snapshot.generation)
        XCTAssertEqual(router.profile.samples.count, 1)
    }

    /// An accepted duplicate advances ordering so an older callback cannot supersede it.
    func testDuplicateAdvancesTimestampBeforeStaleDelivery() {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let path = NWPathMonitor().currentPath
        let now = ContinuousClock.now
        var events: [RoutingConnectionObservation] = []
        router.onConnectionObservation = { events.append($0) }
        router.receiveNativePath(path, observedAt: now)
        router.receiveNativePath(path, observedAt: now.advanced(by: .seconds(2)))
        router.receiveNativePath(path, observedAt: now.advanced(by: .seconds(1)))
        XCTAssertEqual(events.map(\.disposition), [.applied, .duplicate, .stale])
        XCTAssertEqual(router.snapshot().generation, 1)
    }

    /// Explicit updates still invalidate same-coarse history; the following native path is not mistaken for a duplicate.
    func testManualUpdateInvalidatesAndResetsNativeBaseline() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let path = NWPathMonitor().currentPath
        let now = ContinuousClock.now
        var events: [RoutingConnectionObservation] = []
        router.onConnectionObservation = { events.append($0) }
        router.receiveNativePath(path, observedAt: now)
        _ = try await router.measure(model: .cloud, inputTokens: 100, snapshot: router.snapshot()) { "sample" }
        router.updateConnection(router.snapshot().connection, observedAt: now.advanced(by: .seconds(2)))
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertEqual(router.snapshot().generation, 2)
        router.receiveNativePath(path, observedAt: now.advanced(by: .seconds(3)))
        XCTAssertEqual(router.snapshot().generation, 3)
        XCTAssertEqual(events.last?.disposition, .applied)
        XCTAssertNil(events.last?.nativeEqual)
    }

    /// Reordered manual updates cannot erase the native baseline used for later duplicate detection.
    func testStaleManualUpdateDoesNotResetNativeBaseline() {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let path = NWPathMonitor().currentPath
        let now = ContinuousClock.now
        var events: [RoutingConnectionObservation] = []
        router.onConnectionObservation = { events.append($0) }
        router.receiveNativePath(path, observedAt: now)
        router.updateConnection(.init(kind: .cellular), observedAt: now.advanced(by: .seconds(-1)))
        router.receiveNativePath(path, observedAt: now.advanced(by: .seconds(1)))
        XCTAssertEqual(events.map(\.disposition), [.applied, .stale, .duplicate])
        XCTAssertEqual(router.snapshot().generation, 1)
    }

    /// The diagnostic value is captured after commit and remains truthful if its observer reenters the router.
    func testObserverReentrancyCannotRewriteEmittedGeneration() {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let path = NWPathMonitor().currentPath
        let now = ContinuousClock.now
        router.receiveNativePath(path, observedAt: now)
        var duplicate: RoutingConnectionObservation?
        router.onConnectionObservation = { event in
            if event.disposition == .duplicate {
                router.updateConnection(.init(kind: .cellular), observedAt: now.advanced(by: .seconds(2)))
                duplicate = event
            }
        }
        router.receiveNativePath(path, observedAt: now.advanced(by: .seconds(1)))
        XCTAssertEqual(duplicate?.generationBefore, 1)
        XCTAssertEqual(duplicate?.generationAfter, 1)
        XCTAssertEqual(router.snapshot().generation, 2)
        XCTAssertEqual(router.snapshot().connection.kind, .cellular)
        router.onConnectionObservation = nil
    }
}
