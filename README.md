# AdaptiveModelRouting

A Swift package that learns when to use an on-device model or a preferred cloud model such as Private Cloud Compute.

It starts cloud-first, learns from real request timings on the current device and connection, and chooses local inference when it has a meaningful speed advantage. One product and one import provide the Apple adapter, routing presets and detailed results. Apps can also supply their own inference closures.

Build with an **iOS/macOS 27 SDK**; validation currently uses Xcode 27.3. Core routing APIs support **iOS 26+** and **macOS 26+**. The Apple adapter requires an **iOS/macOS 27 runtime**. The package uses Apple's Foundation, Network, Foundation Models and CryptoKit frameworks, with no third-party dependencies.

## Add the package

This is a private repository. Consumers need read access through their authenticated Git or Xcode account. The APIs documented here require the development branch until the next tagged release; **0.1.0 predates the request policies and Apple adapter**:

```swift
.package(url: "https://github.com/coryparrry/AdaptiveModelRouting.git", branch: "main")
```

Add `.product(name: "AdaptiveModelRouting", package: "AdaptiveModelRouting")` to your target. Everything is available through `import AdaptiveModelRouting`. Use a tagged version or commit revision for reproducible production builds once the desired changes are available.

## Use Apple Foundation Models

On iOS/macOS 27+, keep one adapter alive for each stable workload:

```swift
import AdaptiveModelRouting

// In an @MainActor app model:
let router = FoundationModelsRouter(
    workload: "summaries",
    instructions: "Summarize accurately and concisely.",
    configuration: .qualityFirst
)

let summary = try await router.respond(to: transcript)
let complexAnswer = try await router.respond(to: complexQuestion, policy: .cloudRequired)
```

The adapter checks local/PCC readiness and known PCC quota exhaustion, creates a fresh session per operation, tokenizes the complete local transcript, and maps Apple's explicit network, quota, service, timeout and rate-limit errors to recovery. Unknown errors, refusals, guardrail violations and context-limit errors propagate unchanged. PCC still requires Apple's managed entitlement in the consuming app; constructing an adapter does not grant access.

The default output limit is 512 tokens. Supply Apple's `GenerationOptions` as `options:` to customize sampling and output limits. An unset limit uses the router's configured local reserve. The actual maximum response limit is also reserved in the local context guard. SDK-normalized options are used as supplied by Foundation Models.

For structured output, import `FoundationModels`, declare an `@Generable` type, and call `respond(to:generating:)` or `respondDetailed(to:generating:)`. The schema participates in local token counting. [AppleGenerator](AppleExamples/AppleGenerator.swift) is a compiled structured-output example.

This initial adapter supports text and structured output with fresh sessions, without tools or shared conversation histories. Its local token count is a routing size measure, not a claim about the PCC tokenizer. PCC enforces its own context limit; native context errors remain visible. Cloud-required requests skip local tokenization entirely. If local tokenization is unavailable or fails recoverably, a permitted cloud request can proceed without local calibration; the adapter does not invent an input token count for training.

Workload names select fixed-length, hashed cache-directory names. Use a distinct workload for different instructions, models or generation settings and keep one owner per workload/cache root. Customize `cacheRoot`, `localModel`, `cloudModel` and `shouldFallback` at initialization when needed.

## Presets and overrides

- `.balanced` preserves the original cloud-first defaults, three samples per lane and a one-deviation timing allowance.
- `.qualityFirst` requires five samples per lane, at least 750 ms/40% local savings, and a 1.5-deviation allowance.
- `.latencyFirst` requires three samples, at least 100 ms/10% local savings, and a 0.5-deviation allowance.

Presets tune latency policy; they do not measure output quality or relax `.cloudRequired`. Override any setting while retaining the rest of a preset:

```swift
let configuration = RoutingConfiguration(
    customizing: .qualityFirst,
    localResponseReserve: 768,
    failureBackoff: 120,
    cloudRetryInterval: 300
)
```

Configuration also exposes sample count, prediction sample limit, size tolerance, sample lifetime, local refresh interval, variability allowance and slow-cloud threshold. Invalid configuration is rejected at initialization.

## Explain a result

Both the core router and Apple adapter offer `respondDetailed`. The original core `respond` still returns `Value?`; the Apple convenience `respond` returns a value or throws `FoundationModelsAdapterError.noResult` with the no-result status.

```swift
let result = try await router.respondDetailed(to: transcript)
print(result.decision.reason.rawValue) // Original selection reason
print(result.route as Any)            // Provider that actually produced the result
print(result.didFallback)
print(result.attempts)                // Provider, elapsed seconds and outcome only
```

`status` distinguishes `.completed`, `.requiresChunking` and `.unavailable`. A result with no output has no successful `route`. Diagnostics include readiness and, when enough evidence exists, weighted latency predictions, variability and sample counts. `decision` previews selection without inference. Provider errors still throw their original types; pass `onAttempt:` to observe failed or cancelled attempts before an error propagates. No raw error text, prompt or output is included in attempt metadata or persisted calibration.

## Use the core with provider closures

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
- With the balanced preset, compares at least three recent observations per lane within 25% of input size and expected output size, weighting recent measurements more heavily. Unspecified output sizes match only other unspecified sizes. Presets and overrides can change these limits.
- Separates fresh and reused sessions for each provider using `RoutingWorkload(localSession:cloudSession:)`. Keep separate routers for tasks with materially different prompts or generation settings; metadata is supplied by the caller, not inferred from model contents.
- Accounts for weighted timing spread: local must remain faster after subtracting the configured variability allowance from cloud latency and adding it to local latency (one standard deviation per provider by default). This is a conservative heuristic, not a statistical confidence guarantee or a quality evaluation.
- By default, local must save at least **350 ms** and **25%** of predicted cloud latency. Both margins and the local response reserve are configurable.
- Separates cloud history by Wi-Fi, cellular, wired/other, and expensive/constrained path flags. Local timings remain device-specific across connections.
- Backs off for 60 seconds after failure, and periodically retries cloud after ten minutes rather than freezing on an old slow connection. Local calibration can refresh after 30 minutes.
- Marks cloud requests still pending after the configured slow limit (20 seconds by default) for health backoff. This watch does not terminate the request: the consuming app should supply its own overall deadline/cancellation policy.

Use `PerformanceProfile` directly for deterministic policy decisions, `InferenceExecutor` for fallback execution alone, or `AdaptiveRouter` for integrated observation, persistence and execution. `monitorConnection: false` and `updateConnection` support deterministic testing or caller-owned network observation.

## Local data

History retains at most 128 timings per provider (256 total), so frequent requests to one provider cannot evict the other provider's calibration. Prediction sample limits and minimums cannot exceed 128.

The bounded, backup-excluded cache contains only route, input token count, expected output token count, session-reuse flags, elapsed time, timestamp, coarse path flags and OS version. It stores no prompts, outputs, meeting questions, SSIDs, IP addresses or account identifiers. Older caches without workload metadata remain readable as fresh sessions with unspecified output size. iPhone cache files use protection until first authentication. OS updates reset calibration, and unreadable caches are preserved instead of overwritten. There is no built-in telemetry or calibration server.

The app controls what its inference closures send to a cloud provider. Use one owner per cache directory; sharing a directory between multiple router instances or processes is not supported.

## Verify

```sh
swift test
swift test -c release
swift build -c release
swift build --package-path Tests/SingleImportConsumer
```

Tests use injected timings, provider closures and Apple backend operations, require no cloud entitlement, and make no model requests. They cover bootstrap, presets, diagnostics, device/connection differences, recovery, persistence, cancellation, legacy API use, native error classification and Generable decoding. Both examples compile. The separate consumer fixture verifies that the Apple adapter, explicit configuration and detailed results work with one product and one import. Actual tokenization, generation quality, signed PCC access and live network handoff still require qualification in a consuming app.

## License

MIT. See [LICENSE](LICENSE).
