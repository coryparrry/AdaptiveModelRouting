import Foundation
import XCTest
@testable import AdaptiveModelRouting

/// Replays the measured mixed-workload regression without making provider calls.
final class QuotaStabilityTests: XCTestCase {
    /// Loads twelve recorded latency samples, with paired provenance and relative dates only.
    private func recordedProfile() throws -> PerformanceProfile {
        try JSONDecoder().decode(PerformanceProfile.self, from: Data(Self.recorded.utf8))
    }

    /// An isolated local spike must not promote PCC repeatedly against mixed paired evidence.
    func testRecordedLocalSpikeDoesNotOscillateIntoPaidCloud() throws {
        var profile = try recordedProfile()
        let wifi = PerformanceProfile.Connection(kind: .wifi)
        let workload = RoutingWorkload(expectedOutputTokens: 256)
        for (index, seconds) in [0.426326, 0.959161, 0.973750].enumerated() {
            let now = Date(timeIntervalSinceReferenceDate: Double(index + 1))
            let decision = profile.decision(inputTokens: 313, localCapacity: 8_192,
                connection: wifi, now: now, workload: workload)
            XCTAssertEqual(decision.route, .onDevice, "request \(index + 23)")
            profile.record(model: .onDevice, tokens: 313, seconds: seconds, connection: wifi,
                now: now, workload: workload)
        }
    }


    /// Builds a mixed-evidence history followed by two unpaired local spikes.
    private func mixedProfile() -> PerformanceProfile {
        var profile = PerformanceProfile()
        for index in 0..<3 {
            let id = UUID()
            record(&profile, .onDevice, 0.4, at: Double(index * 2 - 10), pair: id)
            record(&profile, .cloud, 0.8, at: Double(index * 2 - 9), pair: id)
        }
        record(&profile, .onDevice, 1.8, at: -2)
        record(&profile, .onDevice, 1.0, at: -1)
        return profile
    }

    /// Records deterministic successful observations without sleeping or invoking a model.
    private func record(_ profile: inout PerformanceProfile, _ model: InferenceRoute,
        _ seconds: Double, at: Double, pair: UUID? = nil
    ) {
        profile.record(model: model, tokens: 100, seconds: seconds, connection: .init(kind: .wifi),
            now: Date(timeIntervalSinceReferenceDate: at), workload: .init(), configuration: .fastest,
            comparisonID: pair)
    }

    /// Selects a comparable request at a stable reference time.
    private func decision(_ profile: PerformanceProfile, configuration: RoutingConfiguration = .fastest,
        policy: RoutingPolicy = .automatic, capacity: Int = 8_192,
        availability: RoutingAvailability = .init(), consumed: Date? = nil
    ) -> RoutingDecision {
        profile.executionDecision(inputTokens: 100, localCapacity: capacity, connection: .init(kind: .wifi),
            now: Date(timeIntervalSinceReferenceDate: 10), configuration: configuration, policy: policy,
            workload: .init(), availability: availability, lastCloudUse: nil, lastLocalLearning: consumed)
    }

    /// Sustained local degradation promotes cloud after the configured number of confirmations.
    func testSustainedSlowdownCanPromoteCloud() {
        var profile = mixedProfile()
        XCTAssertEqual(decision(profile).route, .onDevice)
        record(&profile, .onDevice, 2, at: 0)
        XCTAssertEqual(decision(profile).route, .cloud)
    }

    /// A decisive new cloud probe can promote immediately against every recent local observation.
    func testClearlyFasterCloudProbeCanPromoteImmediately() {
        var profile = mixedProfile()
        let id = UUID()
        record(&profile, .onDevice, 1, at: 0, pair: id)
        record(&profile, .cloud, 0.1, at: 1, pair: id)
        XCTAssertEqual(decision(profile).route, .cloud)
    }

    /// Two recent cloud-winning comparisons replace old local-winning evidence.
    func testRepeatedMatchedCloudWinsAllowPromotion() {
        var profile = mixedProfile()
        for index in 0..<2 {
            let id = UUID()
            record(&profile, .onDevice, 2, at: Double(index * 2), pair: id)
            record(&profile, .cloud, 0.8, at: Double(index * 2 + 1), pair: id)
        }
        XCTAssertEqual(decision(profile).route, .cloud)
    }

    /// Both completion orders retain the actual matched latency through Codable round trips.
    func testMatchedComparisonSurvivesEitherCompletionOrderAndPruning() throws {
        for localFirst in [true, false] {
            var profile = PerformanceProfile()
            let id = UUID()
            record(&profile, localFirst ? .onDevice : .cloud, localFirst ? 0.4 : 0.8, at: -2, pair: id)
            record(&profile, localFirst ? .cloud : .onDevice, localFirst ? 0.8 : 0.4, at: -1, pair: id)
            for index in 0..<130 { record(&profile, .onDevice, 1, at: Double(index)) }
            let decoded = try JSONDecoder().decode(PerformanceProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(decoded.samples.filter { $0.model == .onDevice }.count, 128)
            XCTAssertFalse(decoded.samples.contains { $0.model == .onDevice && $0.comparisonID == id })
            XCTAssertEqual(decoded.samples.first { $0.model == .cloud }?.localComparisonSeconds, 0.4)
        }
    }

    /// Missing, mismatched or rejected local results cannot invent paired evidence.
    func testIncompleteComparisonsDoNotAuthorizeConfirmation() {
        var profile = PerformanceProfile()
        for index in 0..<3 {
            record(&profile, .cloud, 0.8, at: Double(index * 2 - 9), pair: UUID())
            record(&profile, .onDevice, 2, at: Double(index * 2 - 8), pair: UUID())
        }
        record(&profile, .onDevice, .nan, at: -1, pair: profile.samples.first!.comparisonID)
        XCTAssertTrue(profile.samples.filter { $0.model == .cloud }.allSatisfy { $0.localComparisonSeconds == nil })
        XCTAssertEqual(decision(profile).route, .cloud)
    }

    /// Explicit quota opt-out, presets, provider constraints keep their authority.
    func testConfirmationRespectsConfigurationAndConstraints() {
        let profile = mixedProfile()
        XCTAssertEqual(decision(profile).reason, .localCalibration)
        XCTAssertEqual(decision(profile, configuration: .init(conserveCloudQuota: false)).route, .cloud)
        XCTAssertEqual(decision(profile, configuration: .init(calibration: .singleProvider)).route, .cloud)
        XCTAssertEqual(decision(profile, configuration: .balanced).route, .cloud)
        XCTAssertEqual(decision(profile, policy: .cloudRequired).reason, .cloudRequired)
        XCTAssertEqual(decision(profile, policy: .localOnly).reason, .localOnly)
        XCTAssertEqual(decision(profile, capacity: 100).reason, .localContextExceeded)
        XCTAssertEqual(decision(profile, availability: .init(onDevice: false)).reason, .localUnavailable)
        XCTAssertEqual(decision(profile, consumed: Date(timeIntervalSinceReferenceDate: 0)).route, .onDevice)
    }

    /// Cloud-session matches cannot import contradictory local evidence from another session bucket.
    func testPairedEvidenceRespectsBothLocalSessionDirectionsAfterPruningAndReload() throws {
        for current in [RoutingWorkload.SessionState.fresh, .reused] {
            let other: RoutingWorkload.SessionState = current == .fresh ? .reused : .fresh
            var profile = mixedProfile()
            for index in 0..<130 { record(&profile, .onDevice, 0.4, at: Double(index)) }
            record(&profile, .onDevice, 1.8, at: 130)
            record(&profile, .onDevice, 1.0, at: 131)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
            object["samples"] = (object["samples"] as! [[String: Any]]).map { sample in
                var changed = sample
                var workload = changed["workload"] as! [String: Any]
                workload["localSession"] = sample["model"] as! String == "cloud" ? other.rawValue : current.rawValue
                changed["workload"] = workload
                return changed
            }
            let loaded = try JSONDecoder().decode(PerformanceProfile.self,
                from: JSONSerialization.data(withJSONObject: object))
            let result = loaded.decision(inputTokens: 100, localCapacity: 8_192, connection: .init(kind: .wifi),
                now: Date(timeIntervalSinceReferenceDate: 140), workload: .init(localSession: current))
            XCTAssertEqual(result.route, .cloud, "Current local session: \(current)")
        }
    }

    /// The current output budget owns the inclusive 25-percent comparability boundary.
    func testMatchedEvidenceIncludesLowerOutputSizeBoundary() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mixedProfile())) as! [String: Any]
        object["samples"] = (object["samples"] as! [[String: Any]]).map { sample in
            var changed = sample
            var workload = changed["workload"] as! [String: Any]
            workload["expectedOutputTokens"] = 192
            changed["workload"] = workload
            return changed
        }
        let profile = try JSONDecoder().decode(PerformanceProfile.self,
            from: JSONSerialization.data(withJSONObject: object))
        let result = profile.decision(inputTokens: 100, localCapacity: 8_192, connection: .init(kind: .wifi),
            now: Date(timeIntervalSinceReferenceDate: 10), workload: .init(expectedOutputTokens: 256))
        XCTAssertEqual(result.reason, .localCalibration)
    }

    /// Disk-backed execution consumes the regression trace without a new paid provider call.
    @MainActor func testRecordedOwnerAvoidsPaidPromotion() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var object = try JSONSerialization.jsonObject(with: Data(Self.recorded.utf8)) as! [String: Any]
        let anchor = Date.now.timeIntervalSinceReferenceDate - 1
        object["samples"] = (object["samples"] as! [[String: Any]]).map { sample in
            var shifted = sample
            shifted["date"] = (sample["date"] as! Double) + anchor
            return shifted
        }
        let cache: [String: Any] = ["version": 1, "system": "stability", "profile": object,
            "lastCloudUse": anchor]
        try JSONSerialization.data(withJSONObject: cache).write(to: directory.appendingPathComponent("latency.json"))
        let router = AdaptiveRouter(directory: directory, system: "stability", monitorConnection: false)
        router.updateConnection(.init(kind: .wifi))
        var paidCalls = 0
        for _ in 0..<3 {
            let result = try await router.respondDetailed(inputTokens: 313, localContextCapacity: 8_192,
                workload: .init(expectedOutputTokens: 256), cloud: { paidCalls += 1; return "cloud" },
                onDevice: { "local" })
            XCTAssertEqual(result.route, .onDevice)
        }
        XCTAssertEqual(paidCalls, 0)
    }

    /// Concurrent confirmations remain free while the first local observation is still in flight.
    @MainActor func testConcurrentConfirmationDoesNotSpendCloud() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mixedProfile())) as! [String: Any]
        let anchor = Date.now.timeIntervalSinceReferenceDate - 1
        object["samples"] = (object["samples"] as! [[String: Any]]).map { sample in
            var shifted = sample
            shifted["date"] = (sample["date"] as! Double) + anchor
            return shifted
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "system": "concurrent-confirmation",
            "profile": object, "lastCloudUse": anchor]).write(to: directory.appendingPathComponent("latency.json"))
        let router = AdaptiveRouter(directory: directory, system: "concurrent-confirmation", monitorConnection: false)
        router.updateConnection(.init(kind: .wifi))
        let held = ControlledRoutingProvider()
        var paidCalls = 0
        let first = Task { @MainActor in
            try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
                cloud: { paidCalls += 1; return "cloud" }, onDevice: { await held.call() })
        }
        await held.started.wait()
        defer { held.release(); first.cancel() }
        let second = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { paidCalls += 1; return "cloud" }, onDevice: { "local" })
        XCTAssertEqual(second.route, .onDevice)
        held.release("local")
        let result = try await first.value
        XCTAssertEqual(result.route, .onDevice)
        XCTAssertEqual(paidCalls, 0)
    }

    /// The integrated executor associates successful foreground and shadow observations.
    @MainActor func testExecutorRecordsActualMatchedLanes() async throws {
        let router = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        router.updateConnection(.init(kind: .wifi))
        _ = try await router.respondDetailed(inputTokens: 100, localContextCapacity: 8_192,
            cloud: { "cloud" }, onDevice: { "local" })
        while router.isCalibrating { await Task.yield() }
        let cloud = try XCTUnwrap(router.profile.samples.first { $0.model == .cloud })
        let local = try XCTUnwrap(router.profile.samples.first { $0.model == .onDevice })
        XCTAssertNotNil(cloud.comparisonID)
        XCTAssertEqual(cloud.comparisonID, local.comparisonID)
        XCTAssertEqual(cloud.localComparisonSeconds, local.seconds)
    }

    private static let recorded = #"""
{"samples":[{"seconds":0.985090666,"model":"cloud","tokens":313,"connection":{"kind":"wifi","constrained":false,"expensive":false},"date":-1334.3074880838394,"workload":{"expectedOutputTokens":256,"cloudSession":"fresh","localSession":"fresh"},"comparisonID":"00000000-0000-0000-0000-000000000008","localComparisonSeconds":0.424032959},{"model":"cloud","tokens":313,"seconds":2.7351475,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":-811.6741579771042,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"},"comparisonID":"00000000-0000-0000-0000-00000000000d","localComparisonSeconds":3.581470083},{"model":"cloud","tokens":313,"seconds":3.157017083,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":-766.0163390636444,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"},"comparisonID":"00000000-0000-0000-0000-00000000000e","localComparisonSeconds":3.750857833},{"model":"cloud","tokens":313,"seconds":3.271474625,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":-738.4683190584183,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"},"comparisonID":"00000000-0000-0000-0000-00000000000f","localComparisonSeconds":3.711689125},{"model":"cloud","tokens":313,"seconds":0.75569225,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":-630.3181980848312,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"},"comparisonID":"00000000-0000-0000-0000-000000000010","localComparisonSeconds":0.499874458},{"model":"cloud","tokens":313,"seconds":0.844632208,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":-0.17503798007965088,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"},"comparisonID":"00000000-0000-0000-0000-000000000016","localComparisonSeconds":1.019895209},{"model":"onDevice","tokens":313,"seconds":0.529629708,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":-587.999340057373,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"}},{"model":"onDevice","tokens":313,"seconds":0.528769291,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":-484.19430005550385,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"}},{"model":"onDevice","tokens":313,"seconds":0.521839125,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":-359.4674459695816,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"}},{"model":"onDevice","tokens":313,"seconds":0.528,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":-271.5298960208893,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"}},{"model":"onDevice","tokens":313,"seconds":1.758438458,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":-164.8482550382614,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"}},{"model":"onDevice","tokens":313,"seconds":1.019895209,"connection":{"expensive":false,"constrained":false,"kind":"wifi"},"date":0.0,"workload":{"localSession":"fresh","expectedOutputTokens":256,"cloudSession":"fresh"},"comparisonID":"00000000-0000-0000-0000-000000000016"}],"failures":[]}
"""#
}
