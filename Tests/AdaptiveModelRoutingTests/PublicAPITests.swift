import Foundation
import XCTest
import AdaptiveModelRouting
import RoutingExample

/// Exercises the same public interface available to a client app, with generic string outputs.
final class PublicAPITests: XCTestCase {
    /// Compiles and executes the shipped example across the same module boundary as a client app.
    @MainActor
    func testShippedExample() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generator = Generator(router: AdaptiveRouter(directory: directory, monitorConnection: false))
        let output = try await generator.generate(inputTokens: 1_200, localContextCapacity: 8_192,
            cloud: { "cloud output" }, onDevice: { "local output" })
        XCTAssertEqual(output, "cloud output")
    }

    /// A fresh router calls the preferred provider once and records only performance metadata.
    @MainActor
    func testRespondWithPublicClosures() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        var cloudCalls = 0
        var localCalls = 0
        let result = try await router.respond(inputTokens: 1_200, localContextCapacity: 8_192, cloud: {
            cloudCalls += 1
            return "cloud output"
        }, onDevice: {
            localCalls += 1
            return "local output"
        })
        XCTAssertEqual(result, "cloud output")
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(localCalls, 0)
        XCTAssertEqual(router.profile.samples.map(\.model), [.cloud])
    }

    /// Unavailable cloud falls back once, then later requests use the health cooldown.
    @MainActor
    func testRespondLearnsUnavailabilityAndFallsBack() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        var cloudCalls = 0
        var localCalls = 0
        for _ in 0..<2 {
            let result: String? = try await router.respond(inputTokens: 1_200, localContextCapacity: 8_192, cloud: {
                cloudCalls += 1
                return nil
            }, onDevice: {
                localCalls += 1
                return "local output"
            })
            XCTAssertEqual(result, "local output")
        }
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(localCalls, 2)
    }

    /// A failed cloud call records backoff and returns the fitting local result to the client.
    @MainActor
    func testRespondProviderFailureFallsBack() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        let output: String? = try await router.respond(inputTokens: 1_200, localContextCapacity: 8_192,
            cloud: { throw URLError(.notConnectedToInternet) }, onDevice: { "local recovery" })
        XCTAssertEqual(output, "local recovery")
        XCTAssertEqual(router.profile.failures.map(\.model), [.cloud])
        XCTAssertEqual(router.profile.samples.map(\.model), [.onDevice])
    }

    /// Oversized requests return control to the caller instead of overflowing local context.
    @MainActor
    func testRespondReturnsNilForRequiredChunking() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false,
            configuration: .init(localResponseReserve: 1_000))
        let result: String? = try await router.respond(inputTokens: 7_500, localContextCapacity: 8_192,
            cloud: { nil }, onDevice: {
                XCTFail("Custom response reservation must be included in the context guard.")
                return "too large"
            })
        XCTAssertNil(result)
    }

    /// Explicit and task-level cancellation propagate through the public orchestration method.
    @MainActor
    func testRespondPreservesCancellation() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let router = AdaptiveRouter(directory: directory, monitorConnection: false)
        for explicit in [true, false] {
            let operation = Task {
                try await router.respond(inputTokens: 1_200, localContextCapacity: 8_192, cloud: {
                    if explicit { throw CancellationError() }
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "cancelled output"
                }, onDevice: {
                    XCTFail("Cancelled cloud work must not start a local request.")
                    return "local output"
                })
            }
            do {
                _ = try await operation.value
                XCTFail("Cancellation must reach the caller.")
            } catch is CancellationError {}
        }
        XCTAssertTrue(router.profile.samples.isEmpty)
        XCTAssertTrue(router.profile.failures.isEmpty)
    }

    /// The configurable quality margin can change preference using exactly the same observations.
    func testConfigurableQualityPreference() {
        let now = Date.now
        let connection = PerformanceProfile.Connection(kind: .wifi)
        var profile = PerformanceProfile()
        for index in 0..<3 {
            let date = now.addingTimeInterval(Double(index - 3))
            profile.record(model: .onDevice, tokens: 1_200, seconds: 1, connection: connection, now: date)
            profile.record(model: .cloud, tokens: 1_200, seconds: 1.2, connection: connection, now: date)
        }
        XCTAssertEqual(profile.choose(inputTokens: 1_200, localCapacity: 8_192, connection: connection, now: now), .cloud)
        XCTAssertEqual(profile.choose(inputTokens: 1_200, localCapacity: 8_192, connection: connection, now: now,
            configuration: .init(minimumLocalSavingSeconds: 0, minimumLocalSavingFraction: 0)), .onDevice)
    }

    /// Existing prototype caches decode into the package's provider-neutral route name.
    func testLegacyRouteCacheCompatibility() throws {
        let route = try JSONDecoder().decode(InferenceRoute.self, from: Data("\"pcc\"".utf8))
        XCTAssertEqual(route, .cloud)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(route), as: UTF8.self), "\"cloud\"")
    }

    /// Integer boundaries cannot overflow context checking on invalid provider capacity values.
    func testContextBounds() {
        XCTAssertFalse(InferenceExecutor.fitsLocal(inputTokens: 1, localCapacity: .min))
        XCTAssertFalse(InferenceExecutor.fitsLocal(inputTokens: -1, localCapacity: 8_192))
        XCTAssertFalse(InferenceExecutor.fitsLocal(inputTokens: 0, localCapacity: 8_192, responseReserve: -1))
        XCTAssertTrue(InferenceExecutor.fitsLocal(inputTokens: 7_792, localCapacity: 8_192))
        XCTAssertFalse(InferenceExecutor.fitsLocal(inputTokens: 7_793, localCapacity: 8_192))
    }

    /// A local provider error retries cloud once with the same generic result type.
    @MainActor
    func testExecutorRetriesFailedLocalWithoutRepeatingIt() async throws {
        var localCalls = 0
        var cloudCalls = 0
        let output: Int? = try await InferenceExecutor.respond(preferred: .onDevice, canUseLocalWhole: true, cloud: {
            cloudCalls += 1
            return 42
        }, onDevice: {
            localCalls += 1
            throw URLError(.unknown)
        })
        XCTAssertEqual(output, 42)
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(cloudCalls, 1)
    }

    /// An oversized cloud error propagates instead of attempting another oversized local request.
    @MainActor
    func testExecutorPreservesOversizedProviderError() async throws {
        do {
            let _: String? = try await InferenceExecutor.respond(preferred: .cloud, canUseLocalWhole: false,
                cloud: { throw URLError(.notConnectedToInternet) },
                onDevice: { XCTFail("The caller must split oversized local input."); return "invalid" })
            XCTFail("The caller must receive provider failure.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }
}
