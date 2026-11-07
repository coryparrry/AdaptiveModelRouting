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
    policy: .automatic, // Use only for tasks where local output quality is acceptable.
    workload: .init(expectedOutputTokens: 512),
    cloud: { try await generateWithPrivateCloudCompute() },
    onDevice: { try await generateLocally() }
)
```

The counts and generation functions above belong to your app. Count the full input, including instructions, prior session context and structured output schemas, and reserve enough room for generation. The local context guard reserves the larger of `localResponseReserve` and `expectedOutputTokens`. The expectation is a routing hint, not a generation limit; configure the provider's actual output limit separately. Outputs can be any type supported by your closures, including structured model results. The [compiled example](Examples/Generator.swift) shows the provider-independent interface and is exercised by the package tests.

Return `nil` from the cloud closure when the provider is unavailable, out of quota or cannot fit the request, and local recovery is appropriate. Throw provider errors normally. Cancellation is propagated without starting another inference. A `nil` overall result means no permitted whole-request result is available; the caller can chunk the input or apply its own recovery behavior. For oversized local requests, the package never attempts an overflowing whole-local call.

When using Apple Foundation Models, your app owns model availability/quota checks, tokenization, cloud capacity checks and session generation options. PCC still requires the appropriate entitlement and signing profile in the consuming app. The package does not provision access or supply an API key.

## Quality requirements and errors

Use `policy: .cloudRequired` when a task requires cloud capabilities. This overrides learned speed, local calibration, offline selection and all local fallback. If cloud returns `nil`, the request returns `nil`; if cloud throws, its error reaches the caller. The router never relaxes this constraint automatically.

The default error policy permits fallback for recognized temporary `URLError` failures such as timeout or lost connectivity. Other errors propagate unchanged and do not themselves record a model-health failure. In particular, unknown provider errors, safety refusals, invalid input and certificate failures do not trigger another model automatically. This changes the previous behavior that retried every non-cancellation error.

Supply `shouldFallback` to classify provider-specific errors, for example a known quota-exhaustion error:

```swift
let result: String? = try await router.respond(
    inputTokens: requestTokens,
    localContextCapacity: localModelCapacity,
    shouldFallback: { route, error in
        // Your adapter must distinguish quota/network errors from refusals and invalid requests.
        isRecoverableProviderError(route, error)
    },
    cloud: { try await generateWithPrivateCloudCompute() },
    onDevice: { try await generateLocally() }
)
```

The classifier runs once per thrown provider error, including terminal failures when there is no permitted fallback. Returning `true` records health backoff and permits the other lane only if the request policy and capacity allow it. Each lane is attempted at most once. Cancellation bypasses the classifier. Slow-request backoff is independent: a cloud request that exceeds `slowCloudAfter` can already have triggered backoff even if it later throws a nonretryable error or is cancelled. Cloud-required requests still never run local inference. A provider that performs tool calls or other side effects must make retries safe before the app enables fallback.

## Learning and recovery

- Initially prefers cloud inference, with a product preference for its reasoning quality rather than a claim that it is always more accurate.
- Selects one local request after three comparable cloud requests until it has three local observations. Calibration does not shadow-run both models; provider failures can still invoke normal fallback.
- Compares at least three recent observations per lane within 25% of input size and expected output size, weighting recent measurements more heavily. Unspecified output sizes match only other unspecified sizes.
- Separates fresh and reused sessions for each provider using `RoutingWorkload(localSession:cloudSession:)`. Keep separate routers for tasks with materially different prompts or generation settings; metadata is supplied by the caller, not inferred from model contents.
- Accounts for weighted timing spread: local must remain faster after subtracting one standard deviation from cloud latency and adding one to local latency. This is a conservative heuristic, not a statistical confidence guarantee or a quality evaluation.
- By default, local must save at least **350 ms** and **25%** of predicted cloud latency. Both margins and the local response reserve are configurable.
- Separates cloud history by Wi-Fi, cellular, wired/other, and expensive/constrained path flags. Local timings remain device-specific across connections.
- Backs off for 60 seconds after failure, and periodically retries cloud after ten minutes rather than freezing on an old slow connection. Local calibration can refresh after 30 minutes.
- Marks cloud requests still pending after the configured slow limit (20 seconds by default) for health backoff. This watch does not terminate the request: the consuming app should supply its own overall deadline/cancellation policy.

Use `PerformanceProfile` directly for deterministic policy decisions, `InferenceExecutor` for fallback execution alone, or `AdaptiveRouter` for integrated observation, persistence and execution. `monitorConnection: false` and `updateConnection` support deterministic testing or caller-owned network observation.

## Local data

The bounded, backup-excluded cache contains only route, input token count, expected output token count, session-reuse flags, elapsed time, timestamp, coarse path flags and OS version. It stores no prompts, outputs, meeting questions, SSIDs, IP addresses or account identifiers. Older caches without workload metadata remain readable as fresh sessions with unspecified output size. iPhone cache files use protection until first authentication. OS updates reset calibration, and unreadable caches are preserved instead of overwritten. There is no built-in telemetry or calibration server.

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
