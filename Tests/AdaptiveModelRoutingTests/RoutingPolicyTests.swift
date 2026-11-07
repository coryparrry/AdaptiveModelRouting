import Foundation
import XCTest
import AdaptiveModelRouting

/// Exercises quality constraints and error recovery through the public orchestration API.
final class RoutingPolicyTests: XCTestCase {
    /// Distinguishes provider failures that need different app-owned recovery decisions.
    private enum ProviderError: Error { case refusal, invalidInput, quota }

    /// Cloud-required requests bypass offline selection, calibration and nil-result local fallback.
    @MainActor
    func testCloudRequiredNeverRunsLocal() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        for _ in 0..<4 {
            let result: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                policy: .cloudRequired, cloud: { "cloud" },
                onDevice: { XCTFail("Quality constraints apply to calibration too."); return "local" })
            XCTAssertEqual(result, "cloud")
        }
        router.updateConnection(.init(kind: .offline))
        XCTAssertEqual(router.choose(inputTokens: 100, localCapacity: 8_192, policy: .cloudRequired), .cloud)
        let result: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            policy: .cloudRequired, cloud: { nil },
            onDevice: { XCTFail("Unavailability must not relax quality constraints."); return "local" })
        XCTAssertNil(result)
        XCTAssertTrue(router.profile.samples.allSatisfy { $0.model == .cloud })
    }

    /// The executor enforces cloud requirements even when handed a contradictory preferred lane.
    @MainActor
    func testExecutorEnforcesCloudRequirementOnFailure() async throws {
        do {
            let _: Int? = try await InferenceExecutor.respond(preferred: .onDevice, canUseLocalWhole: true,
                policy: .cloudRequired, cloud: { throw URLError(.timedOut) },
                onDevice: { XCTFail("A cloud failure cannot authorize local inference."); return 0 })
            XCTFail("The cloud failure must reach the caller.")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    /// Unknown, safety and invalid-input errors propagate without training a model-health cooldown.
    @MainActor
    func testPermanentErrorsDoNotFallbackOrPoisonHealth() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        for failure in [ProviderError.refusal, .invalidInput, .quota] {
            do {
                let _: Int? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                    cloud: { throw failure },
                    onDevice: { XCTFail("Unclassified provider errors must propagate."); return 0 })
                XCTFail("Provider error must reach the caller.")
            } catch let error as ProviderError { XCTAssertEqual(error, failure) }
        }
        XCTAssertTrue(router.profile.failures.isEmpty)
        XCTAssertTrue(router.profile.samples.isEmpty)
    }

    /// A provider-specific quota classifier runs once and enables fallback and health backoff.
    @MainActor
    func testCustomQuotaRecoveryIsClassifiedOnce() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        var classifications = 0
        let result: String? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
            shouldFallback: { route, error in
                classifications += 1
                XCTAssertEqual(route, .cloud)
                return (error as? ProviderError) == .quota
            }, cloud: { throw ProviderError.quota }, onDevice: { "local" })
        XCTAssertEqual(result, "local")
        XCTAssertEqual(classifications, 1)
        XCTAssertEqual(router.profile.failures.map(\.model), [.cloud])
    }

    /// An app may prohibit recovery even for an otherwise retryable transport failure.
    @MainActor
    func testCustomPolicyCanRejectFallback() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        do {
            let _: Int? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                shouldFallback: { _, _ in false }, cloud: { throw URLError(.timedOut) },
                onDevice: { XCTFail("The caller rejected fallback."); return 0 })
            XCTFail("Rejected failures propagate unchanged.")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertTrue(router.profile.failures.isEmpty)
    }

    /// Both failed lanes update health once without starting a third inference request.
    @MainActor
    func testTerminalFailuresAreClassifiedAndRecordedOnce() async throws {
        for offline in [false, true] {
            let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let router = AdaptiveRouter(directory: directory, monitorConnection: false)
            if offline { router.updateConnection(.init(kind: .offline)) }
            var routes: [InferenceRoute] = []
            do {
                let _: Int? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                    shouldFallback: { route, _ in routes.append(route); return true },
                    cloud: { throw ProviderError.quota }, onDevice: { throw ProviderError.invalidInput })
                XCTFail("The final provider's error must propagate.")
            } catch let error as ProviderError { XCTAssertEqual(error, offline ? .quota : .invalidInput) }
            XCTAssertEqual(routes, offline ? [.onDevice, .cloud] : [.cloud, .onDevice])
            XCTAssertEqual(router.profile.failures.map(\.model), routes)
        }
    }

    /// Cancellation bypasses custom recovery and never records a provider failure.
    @MainActor
    func testCancellationBypassesClassifier() async throws {
        do {
            let _: Int? = try await InferenceExecutor.respond(preferred: .cloud, canUseLocalWhole: true,
                shouldFallback: { _, _ in XCTFail("Cancellation is not a provider failure."); return true },
                cloud: { throw CancellationError() },
                onDevice: { XCTFail("Cancelled work must not change lanes."); return 0 })
            XCTFail("Cancellation must propagate.")
        } catch is CancellationError {}
    }

    /// Cancellation requested during classification wins over both accepted and rejected recovery decisions.
    @MainActor
    func testCancellationDuringClassificationWins() async throws {
        for preferred in [InferenceRoute.cloud, .onDevice] {
            for retry in [false, true] {
                let operation = Task {
                    try await InferenceExecutor.respond(preferred: preferred, canUseLocalWhole: true,
                        shouldFallback: { _, _ in
                            withUnsafeCurrentTask { $0?.cancel() }
                            return retry
                        }, cloud: { () -> Int? in
                            XCTAssertEqual(preferred, .cloud, "Cancelled local work must not reach cloud.")
                            throw URLError(.timedOut)
                        }, onDevice: {
                            XCTAssertEqual(preferred, .onDevice, "Cancelled cloud work must not reach local.")
                            throw URLError(.timedOut)
                        })
                }
                do {
                    _ = try await operation.value
                    XCTFail("Cancellation requested during classification must propagate.")
                } catch is CancellationError {}
            }
        }
    }

    /// Independent latency backoff survives a later nonretryable error without retrying that request.
    @MainActor
    func testSlowPermanentErrorRetainsLatencyBackoff() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false,
            configuration: .init(slowCloudAfter: .milliseconds(5)))
        do {
            let _: Int? = try await router.respond(inputTokens: 100, localContextCapacity: 8_192,
                cloud: {
                    let cutoff = ContinuousClock.now.advanced(by: .seconds(2))
                    while router.profile.failures.isEmpty && ContinuousClock.now < cutoff {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    throw ProviderError.refusal
                }, onDevice: { XCTFail("A slow refusal still cannot trigger immediate fallback."); return 0 })
            XCTFail("The refusal must propagate.")
        } catch let error as ProviderError { XCTAssertEqual(error, .refusal) }
        XCTAssertEqual(router.profile.failures.map(\.model), [.cloud])
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertEqual(router.choose(inputTokens: 100, localCapacity: 8_192), .onDevice)
        XCTAssertEqual(router.choose(inputTokens: 100, localCapacity: 8_192, policy: .cloudRequired), .cloud)
    }

    /// The default classifier admits temporary transport failures while rejecting unknown and security errors.
    func testDefaultErrorClassification() {
        XCTAssertTrue(InferenceExecutor.isRetryable(URLError(.timedOut)))
        XCTAssertTrue(InferenceExecutor.isRetryable(URLError(.notConnectedToInternet)))
        XCTAssertFalse(InferenceExecutor.isRetryable(URLError(.unknown)))
        XCTAssertFalse(InferenceExecutor.isRetryable(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(InferenceExecutor.isRetryable(ProviderError.refusal))
        XCTAssertFalse(InferenceExecutor.isRetryable(CancellationError()))
    }
}
