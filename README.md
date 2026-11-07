# AdaptiveModelRouting

A Swift package that learns when to use an on-device model or a preferred cloud model such as Private Cloud Compute.

It starts cloud-first, learns from real request timings on the current device and connection, and chooses local inference when it has a meaningful speed advantage. The app supplies both inference closures; prompts, model SDKs and output types stay in the app.

Requires **Swift 6.2**, **iOS 26+** or **macOS 26+**. The package has no third-party dependencies and uses only Foundation and Network. A particular provider can require a newer OS or SDK.

## Add the package

This is a private repository. Consumers need read access through their authenticated Git or Xcode account. Add the pinned release:

```swift
.package(url: "https://github.com/coryparrry/AdaptiveModelRouting.git", exact: "0.1.0")
```

Add `.product(name: "AdaptiveModelRouting", package: "AdaptiveModelRouting")` to your target dependencies, or add the local package in Xcode.

## Use it

Keep one router alive per workload, with a separate cache directory for each workload. Create it before inference so the connection monitor can establish the current path.

```swift
import Foundation
import AdaptiveModelRouting

// In your @MainActor app model:
let router = AdaptiveRouter(
    directory: URL.applicationSupportDirectory
        .appendingPathComponent("SummaryRouting"),
    configuration: .init(localResponseReserve: 512)
)

// Inside an async method, using your provider's actual token count and capacity:
let result: String? = try await router.respond(
    inputTokens: requestTokens,
    localContextCapacity: localModelCapacity,
    cloud: { try await generateWithPrivateCloudCompute() },
    onDevice: { try await generateLocally() }
)
```

The counts and generation functions above belong to your app. Count the full input, including instructions and structured output schemas, and reserve enough room for generation. Outputs can be any type supported by your closures, including structured model results. The [compiled example](Examples/Generator.swift) shows the provider-independent interface and is exercised by the package tests.

Return `nil` from the cloud closure when the provider is unavailable, out of quota or cannot fit the request. Throw provider errors normally. Cancellation is propagated without starting another inference. A `nil` overall result means no whole-request result is available; the caller can chunk the input or apply its own recovery behavior. For oversized local requests, the package never attempts an overflowing whole-local call.

When using Apple Foundation Models, your app owns model availability/quota checks, tokenization, cloud capacity checks and session generation options. PCC still requires the appropriate entitlement and signing profile in the consuming app. The package does not provision access or supply an API key.

## Learning and recovery

- Initially prefers cloud inference, with a product preference for its reasoning quality rather than a claim that it is always more accurate.
- Selects one local request after three comparable cloud requests until it has three local observations. Calibration does not shadow-run both models; provider failures can still invoke normal fallback.
- Compares at least three recent observations per lane within 25% of request size, weighting recent measurements more heavily.
- By default, local must save at least **350 ms** and **25%** of predicted cloud latency. Both margins and the local response reserve are configurable.
- Separates cloud history by Wi-Fi, cellular, wired/other, and expensive/constrained path flags. Local timings remain device-specific across connections.
- Backs off for 60 seconds after failure, and periodically retries cloud after ten minutes rather than freezing on an old slow connection. Local calibration can refresh after 30 minutes.
- Marks cloud requests still pending after the configured slow limit (20 seconds by default) for health backoff. This watch does not terminate the request: the consuming app should supply its own overall deadline/cancellation policy.

Use `PerformanceProfile` directly for deterministic policy decisions, `InferenceExecutor` for fallback execution alone, or `AdaptiveRouter` for integrated observation, persistence and execution. `monitorConnection: false` and `updateConnection` support deterministic testing or caller-owned network observation.

## Local data

The bounded, backup-excluded cache contains only route, token count, elapsed time, timestamp, coarse path flags and OS version. It stores no prompts, outputs, meeting questions, SSIDs, IP addresses or account identifiers. iPhone cache files use protection until first authentication. OS updates reset calibration, and unreadable caches are preserved instead of overwritten. There is no built-in telemetry or calibration server.

The app controls what its inference closures send to a cloud provider. Use one owner per cache directory; sharing a directory between multiple router instances or processes is not supported.

## Verify

```sh
swift test
swift test -c release
swift build -c release
```

Tests use injected timings and provider closures, require no cloud entitlement, and make no model requests. They cover healthy-network bootstrap, device/connection differences, recovery, persistence, cancellation, public API use and the example. Actual model quality and live network handoff should be evaluated in the consuming app.

## License

MIT. See [LICENSE](LICENSE).
