import Foundation
import FoundationModels
import XCTest
@testable import AdaptiveModelRouting

/// Exercises quota changes at actual adapter boundaries without consuming anyone's PCC quota.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class PCCQuotaTests: XCTestCase {
    /// Provides a schema for both concrete and partially generated native adapter paths.
    @Generable
    struct Summary { var text: String }

    /// Supplies mutable quota state and a blocked tokenizer so stale permission snapshots are observable.
    private final class Backend: FoundationModelsBackend {
        var availability = RoutingAvailability(cloudQuota: .available)
        var localContextCapacity = 8_192
        var tokenProvider: ControlledRoutingProvider?
        var firstLocalProvider: ControlledRoutingProvider?
        var tokenError: SystemLanguageModel.Error?
        var localError: (any Error)?
        var cloudProvider: ControlledRoutingProvider?
        var cloudError: URLError?
        var localReadiness: [Bool] = []
        var sequence: [CloudQuotaStatus] = []
        var routes: [InferenceRoute] = []
        var tokenCalls = 0
        var policies: [RoutingPolicy] = []

        /// Replays provider quota observations in order while honoring hard policy isolation.
        func availability(for policy: RoutingPolicy) -> RoutingAvailability {
            policies.append(policy)
            let local = policy != .cloudRequired
                && (localReadiness.isEmpty ? availability.onDevice : localReadiness.removeFirst())
            if policy == .localOnly { return .init(onDevice: local, cloud: false) }
            let quota = sequence.isEmpty ? availability.cloudQuota : sequence.removeFirst()
            return .init(onDevice: local, cloud: availability.cloud, cloudQuota: quota)
        }

        /// Can suspend the exact asynchronous preflight boundary where a quota snapshot becomes stale.
        func inputTokens(prompt: String, instructions: String?, schema: GenerationSchema?) async throws -> Int {
            tokenCalls += 1
            if let tokenError { throw tokenError }
            if let tokenProvider { _ = await tokenProvider.call() }
            return 100
        }

        /// Records actual generation separately from availability/readiness inspection.
        func text(route: InferenceRoute, prompt: String, instructions: String?, options: GenerationOptions) async throws -> String {
            routes.append(route)
            if route == .cloud {
                if let cloudProvider { _ = await cloudProvider.call() }
                if let cloudError { throw cloudError }
            } else {
                if let first = firstLocalProvider {
                    firstLocalProvider = nil
                    _ = await first.call()
                }
                if let localError { throw localError }
            }
            return route.rawValue
        }

        /// Uses real Generable decoding for the injected structured result.
        func structured<Content: Generable>(route: InferenceRoute, prompt: String, instructions: String?,
            options: GenerationOptions, generating: Content.Type) async throws -> Content {
            _ = try await text(route: route, prompt: prompt, instructions: instructions, options: options)
            return try Content(GeneratedContent(json: "{\"text\":\"synthetic\"}"))
        }
    }

    /// Invokes each public Apple generation format and requires a completion event even when output is unavailable.
    private func invoke(_ router: FoundationModelsRouter, format: Int, policy: RoutingPolicy = .automatic) async throws -> InferenceRoute? {
        switch format {
        case 0: return try await router.respondDetailed(to: "synthetic", policy: policy).route
        case 1: return try await router.respondDetailed(to: "synthetic", generating: Summary.self, policy: policy).route
        case 2:
            var route: InferenceRoute?
            var completed = false
            for try await event in router.stream(to: "synthetic", policy: policy) {
                if case .completed(let result) = event { route = result.route; completed = true }
            }
            XCTAssertTrue(completed)
            return route
        default:
            var route: InferenceRoute?
            var completed = false
            for try await event in router.stream(to: "synthetic", generating: Summary.self, policy: policy) {
                if case .completed(let result) = event { route = result.route; completed = true }
            }
            XCTAssertTrue(completed)
            return route
        }
    }

    /// An overlapping schema change can retire a local probe without cancelling the original text caller.
    func testSchemaChangeDuringLocalProbePreservesForegroundCloudError() async throws {
        let backend = Backend()
        let cloud = ControlledRoutingProvider()
        let local = ControlledRoutingProvider()
        backend.cloudProvider = cloud
        backend.firstLocalProvider = local
        backend.cloudError = URLError(.networkConnectionLost)
        let core = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
        let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
        defer { cloud.release(); local.release(); router.cancelCalibration() }
        var attempts: [RoutingAttempt] = []
        let first = Task {
            try await router.respondDetailed(to: "first", onAttempt: { attempts.append($0) })
        }
        await cloud.started.wait()
        await local.started.wait()
        let second = try await router.respondDetailed(to: "second", generating: Summary.self, policy: .localOnly)
        XCTAssertEqual(second.route, .onDevice)
        XCTAssertEqual(router.lastCalibrationAttempt?.outcome, .cancelled)
        cloud.release()
        do {
            _ = try await first.value
            XCTFail("The original cloud failure must reach the first caller.")
        } catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        XCTAssertFalse(first.isCancelled)
        XCTAssertEqual(attempts.map(\.outcome), [.failed])
        XCTAssertEqual(backend.routes.filter { $0 == .cloud }.count, 1)
        XCTAssertEqual(backend.routes.filter { $0 == .onDevice }.count, 2)
    }

    /// Losing cloud eligibility during local generation preserves the timeout across all Apple formats.
    func testLocalTimeoutSurvivesSkippedCloudFallback() async throws {
        for format in 0..<4 {
            let backend = Backend()
            backend.localError = URLError(.timedOut)
            backend.sequence = [.available, .available, .exhausted]
            let core = singleProviderRouter(monitorConnection: false, persistence: .memoryOnly)
            core.updateConnection(.init(kind: .offline)) // Prefer local, with recovery subject to fresh quota.
            let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
            do {
                _ = try await invoke(router, format: format)
                XCTFail("A skipped fallback must preserve the local timeout.")
            } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
            XCTAssertEqual(backend.routes, [.onDevice])
            XCTAssertTrue(backend.sequence.isEmpty)
            XCTAssertEqual(core.profile.failures.map(\.model), [.onDevice])
        }
    }

    /// Rechecking quota after an asset error must preserve that error if no provider can generate.
    func testTokenizationFailureSurvivesQuotaLossDuringRecovery() async throws {
        for format in 0..<4 {
            let backend = Backend()
            backend.tokenError = .assetsUnavailable(.init(debugDescription: "fixture"))
            backend.sequence = [.available, .available, .available, .exhausted]
            let core = singleProviderRouter(monitorConnection: false, persistence: .memoryOnly)
            let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
            do {
                _ = try await invoke(router, format: format)
                XCTFail("Expected the tokenization error when cloud recovery could not run.")
            } catch SystemLanguageModel.Error.assetsUnavailable {}
            XCTAssertTrue(backend.routes.isEmpty)
            XCTAssertTrue(backend.sequence.isEmpty)
        }
    }

    /// Local asset loss can recover through cloud at either SDK boundary when the caller permits it.
    func testMissingLocalAssetsRespectProviderPolicy() async throws {
        for format in 0..<4 {
            for duringTokenization in [true, false] {
                for policy in [RoutingPolicy.automatic, .localOnly] {
                    let backend = Backend()
                    let failure = SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "test"))
                    if duringTokenization { backend.tokenError = failure } else { backend.localError = failure }
                    let core = singleProviderRouter(monitorConnection: false, persistence: .memoryOnly)
                    if !duringTokenization { core.updateConnection(.init(kind: .offline)) }
                    let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
                    if policy == .localOnly {
                        do {
                            _ = try await invoke(router, format: format, policy: policy)
                            XCTFail("Asset loss must reach the local-only caller.")
                        } catch SystemLanguageModel.Error.assetsUnavailable {}
                        XCTAssertEqual(backend.routes, duringTokenization ? [] : [.onDevice])
                        XCTAssertTrue(backend.policies.allSatisfy { $0 == .localOnly })
                    } else {
                        let route = try await invoke(router, format: format)
                        XCTAssertEqual(route, .cloud)
                        XCTAssertEqual(backend.routes, duringTokenization ? [.cloud] : [.onDevice, .cloud])
                    }
                }
            }
        }
    }

    /// Quota changing while tokenization awaits must prevent cloud inference on all four adapter APIs.
    func testQuotaChangesDuringPreflightPreventStaleCloudPermission() async throws {
        for format in 0..<4 {
            for quota in [CloudQuotaStatus.approachingLimit, .exhausted] {
                let backend = Backend()
                let tokens = ControlledRoutingProvider()
                backend.tokenProvider = tokens
                let core = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
                let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
                defer { tokens.release(); router.cancelCalibration() }
                let request = Task { try await self.invoke(router, format: format) }
                await tokens.started.wait()
                backend.availability = .init(cloudQuota: quota)
                tokens.release()
                let route = try await request.value
                await router.waitForCalibration()
                XCTAssertEqual(route, .onDevice, "format=\(format), quota=\(quota)")
                XCTAssertEqual(backend.routes, [.onDevice])
                XCTAssertEqual(backend.tokenCalls, 1)
            }
        }
    }

    /// All local-only formats honor readiness lost during tokenization without inspecting PCC.
    func testLocalOnlyRechecksReadinessAfterTokenization() async throws {
        for format in 0..<4 {
            let backend = Backend()
            let tokens = ControlledRoutingProvider()
            backend.tokenProvider = tokens
            let core = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
            let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
            let request = Task { try await self.invoke(router, format: format, policy: .localOnly) }
            await tokens.started.wait()
            backend.availability = .init(onDevice: false, cloud: true)
            tokens.release()

            let route = try await request.value
            XCTAssertNil(route, "format=\(format)")
            XCTAssertTrue(backend.routes.isEmpty)
            XCTAssertEqual(backend.policies, [.localOnly, .localOnly])
            XCTAssertEqual(backend.tokenCalls, 1)
            XCTAssertTrue(core.profile.failures.isEmpty)
        }
    }

    /// Losing local readiness while cloud is running preserves its failure without a second provider call.
    func testUnavailableLocalFallbackPreservesCloudFailure() async throws {
        for format in 0..<4 {
            let backend = Backend()
            let cloud = ControlledRoutingProvider()
            backend.cloudProvider = cloud
            backend.cloudError = URLError(.networkConnectionLost)
            let core = singleProviderRouter(monitorConnection: false, persistence: .memoryOnly)
            let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
            let request = Task { try await self.invoke(router, format: format) }
            await cloud.started.wait()
            backend.availability = .init(onDevice: false, cloud: true)
            cloud.release()
            do {
                _ = try await request.value
                XCTFail("Expected the cloud failure, format=\(format)")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .networkConnectionLost)
            }
            XCTAssertEqual(backend.routes, [.cloud])
            XCTAssertEqual(core.profile.failures.map(\.model), [.cloud])
        }
    }

    /// A paired request can finish on cloud when the local probe loses readiness after preflight.
    func testDeferredLocalCalibrationRechecksReadiness() async throws {
        for format in 0..<4 {
            let backend = Backend()
            backend.localReadiness = [true, true] // Ready before and after tokenization.
            backend.availability = .init(onDevice: false, cloud: true)
            let core = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
            let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
            let route = try await invoke(router, format: format)
            await router.waitForCalibration()
            XCTAssertEqual(route, .cloud, "format=\(format)")
            XCTAssertTrue(backend.policies.contains(.localOnly), "The scheduled probe checked local readiness.")
            XCTAssertEqual(backend.routes, [.cloud])
            XCTAssertFalse(core.profile.samples.contains { $0.model == .onDevice })
            XCTAssertTrue(core.profile.failures.isEmpty)
        }
    }

    /// Successful cloud-required generation restores route health without training on an unknown token count.
    func testCloudRequiredZeroTokenSuccessRestoresAutomaticRouting() async throws {
        for format in 0..<4 {
            let backend = Backend()
            backend.cloudError = URLError(.timedOut)
            let core = singleProviderRouter(monitorConnection: false, persistence: .memoryOnly)
            let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
            do {
                _ = try await invoke(router, format: format, policy: .cloudRequired)
                XCTFail("Expected the initial cloud failure, format=\(format)")
            } catch let error as URLError {
                XCTAssertEqual(error.code, .timedOut)
            }
            XCTAssertEqual(core.profile.failures.map(\.model), [.cloud])

            backend.cloudError = nil
            let recovered = try await invoke(router, format: format, policy: .cloudRequired)
            XCTAssertEqual(recovered, .cloud)
            XCTAssertEqual(backend.tokenCalls, 0)
            XCTAssertTrue(core.profile.failures.isEmpty)
            XCTAssertTrue(core.profile.samples.isEmpty)

            backend.localContextCapacity = 1
            let oversized = try await invoke(router, format: format)
            XCTAssertEqual(oversized, .cloud, "format=\(format)")
            XCTAssertEqual(backend.routes, [.cloud, .cloud, .cloud])
        }
    }

    /// Even a change after preflight is complete must be rechecked at the final dispatch boundary.
    func testQuotaChangesImmediatelyBeforeGenerationAreRechecked() async throws {
        for format in 0..<4 {
            for quota in [CloudQuotaStatus.approachingLimit, .exhausted] {
                let backend = Backend()
                backend.sequence = [.available, .available, quota]
                backend.availability = .init(cloudQuota: quota)
                let core = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
                let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
                let route = try await invoke(router, format: format)
                await router.waitForCalibration()
                XCTAssertEqual(route, .onDevice)
                XCTAssertEqual(backend.routes, [.onDevice], "format=\(format), quota=\(quota)")
                XCTAssertFalse(core.profile.failures.contains { $0.model == .cloud },
                    "Quota eligibility is not a provider-health failure.")
                backend.availability = .init(cloudQuota: .available)
                let recovered = try await invoke(router, format: format)
                await router.waitForCalibration()
                XCTAssertEqual(recovered, .cloud, "A quota reset must not inherit a false failure backoff.")
            }
        }
    }

    /// Hard cloud requests can explicitly use near-limit quota, but an exhausted quota never dispatches.
    func testCloudRequiredQuotaSemanticsRemainExplicit() async throws {
        for format in 0..<4 {
            for quota in [CloudQuotaStatus.approachingLimit, .exhausted] {
                let backend = Backend()
                backend.availability = .init(cloudQuota: quota)
                let core = AdaptiveRouter(monitorConnection: false, persistence: .memoryOnly)
                let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
                let route = try await invoke(router, format: format, policy: .cloudRequired)
                XCTAssertEqual(route, quota == .exhausted ? nil : .cloud)
                XCTAssertEqual(backend.routes, quota == .exhausted ? [] : [.cloud])
                XCTAssertEqual(backend.tokenCalls, 0)
                XCTAssertTrue(backend.policies.allSatisfy { $0 == .cloudRequired })
            }
        }
    }

    /// Quota changing after preparation also blocks an optional probe when foreground quota use is opted in.
    func testQuotaRecheckBlocksALateOptionalPCCProbe() async throws {
        for format in 0..<4 {
            let backend = Backend()
            let core = AdaptiveRouter(monitorConnection: false,
                configuration: .init(cloudRetryInterval: 0.000001, conserveCloudQuota: false), persistence: .memoryOnly)
            let router = FoundationModelsRouter(router: core, options: .init(maximumResponseTokens: 128), backend: backend)
            _ = try await invoke(router, format: format, policy: .localOnly)
            for _ in 0..<3 {
                _ = try await core.measure(model: .cloud, inputTokens: 100, snapshot: core.snapshot(),
                    workload: .init(expectedOutputTokens: 128)) {
                        try await Task.sleep(for: .milliseconds(10)); return "synthetic cloud"
                    }
                _ = try await core.measure(model: .onDevice, inputTokens: 100, snapshot: core.snapshot(),
                    workload: .init(expectedOutputTokens: 128)) { "synthetic local" }
            }
            backend.routes = []
            backend.sequence = [.available, .available, .approachingLimit]
            backend.availability = .init(cloudQuota: .approachingLimit)
            let route = try await invoke(router, format: format)
            await router.waitForCalibration()
            XCTAssertEqual(route, .onDevice)
            XCTAssertEqual(backend.routes, [.onDevice], "Optional PCC dispatch must recheck quota, format=\(format)")
        }
    }

    /// Explicit foreground opt-in cannot enable a secondary PCC calibration call near its quota limit.
    func testForegroundOptInStillBlocksOptionalCloudCalibration() async throws {
        let backend = Backend()
        backend.availability = .init(cloudQuota: .approachingLimit)
        let core = AdaptiveRouter(monitorConnection: false,
            configuration: .init(conserveCloudQuota: false), persistence: .memoryOnly)
        let router = FoundationModelsRouter(router: core, options: .init(), backend: backend)
        XCTAssertTrue(router.allowsCloud(policy: .automatic, calibration: false))
        XCTAssertFalse(router.allowsCloud(policy: .automatic, calibration: true))
        backend.availability = .init(cloudQuota: .exhausted)
        XCTAssertFalse(router.allowsCloud(policy: .automatic, calibration: false))
        XCTAssertFalse(router.allowsCloud(policy: .cloudRequired, calibration: false))
        XCTAssertTrue(backend.routes.isEmpty)
    }
}
