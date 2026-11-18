# AdaptiveModelRouting

AdaptiveModelRouting is a Swift package for iOS and macOS that routes language model requests between an on-device model and a cloud model such as Apple’s Private Cloud Compute. When either model can do the job, it learns from response times on the device and chooses the provider it expects to answer faster for the request size and current connection.

- **Control where each prompt goes.** Use `.localOnly` to keep a sensitive request on the device, `.cloudRequired` for a task that needs the cloud model, or `.automatic` to let the router choose. By default, automatic calibration can send the same prompt to both providers.
- **Handle temporary failures and quota limits.** The router respects provider retry deadlines, spaces out optional cloud calls, and can fall back when policy permits. Once streaming output reaches the caller, the response stays with that provider.
- **Use one API for text, structured output, and streaming.** The Apple Foundation Models adapter supports all three. Apps with their own inference providers can supply Swift closures to the core router.
- **See why a request went local or cloud.** Detailed results report the selection reason, which provider answered, and how long each attempt took. Calibration stays on the device and stores no prompts or generated responses.

Build with an **iOS/macOS 27 SDK**; validation currently uses Xcode 27.3. Core routing APIs support **iOS 26+** and **macOS 26+**. The Apple adapter requires an **iOS/macOS 27 runtime**. The package uses Apple's Foundation, Network, Foundation Models and CryptoKit frameworks, with no third-party dependencies.

## Add the package

This is a private repository. Consumers need read access through their authenticated Git or Xcode account. Version 0.1.0 predates the Apple adapter. To test the features documented in this candidate before it is tagged, point your app at the local checkout.

```swift
.package(path: "../AdaptiveModelRouting")
```

Add `.product(name: "AdaptiveModelRouting", package: "AdaptiveModelRouting")` to your target. Everything is available through `import AdaptiveModelRouting`. Use a tagged version or commit revision for reproducible production builds once the desired changes are available.

### Upgrading from 0.1.0

Automatic routing now uses paired calibration by default. Both provider closures can receive the same prompt, and secondary work may continue after the foreground answer returns. Choose `RoutingConfiguration(calibration: .singleProvider)` to disable parallel calibration. Use `.localOnly` for requests that must stay on the device. A permitted fallback can still call the other provider in single-provider mode.

The default selector now prefers the lowest measured latency. The default 60-second deadline covers preflight, generation and fallback together. Provider closures passed through a wrapper must be escaping and main-actor isolated. The default disk cache now uses a per-app directory, so apps using the old default start with fresh timings. Apps supplying their own directory can reuse compatible caches.

## Use Apple Foundation Models

On iOS/macOS 27+, keep one adapter alive for each stable workload:

```swift
import AdaptiveModelRouting

// In an @MainActor app model:
let router = FoundationModelsRouter(
    workload: "summaries",
    instructions: "Summarize accurately and concisely.",
    configuration: .fastest
)

let summary = try await router.respond(to: transcript)
let complexAnswer = try await router.respond(to: complexQuestion, policy: .cloudRequired)
let privateSummary = try await router.respond(to: transcript, policy: .localOnly)
```

The adapter checks local/PCC readiness and known PCC quota exhaustion, creates a fresh session per operation, tokenizes the complete local transcript, and maps Apple's explicit network, quota, service, timeout and rate-limit errors to recovery. Unknown errors, refusals, guardrail violations and context-limit errors propagate unchanged. PCC still requires Apple's managed entitlement in the consuming app; constructing an adapter does not grant access.

The default output limit is 512 tokens. Supply Apple's `GenerationOptions` as `options:` to customize sampling and output limits. An unset limit uses the router's configured local reserve. The actual maximum response limit is also reserved in the local context guard. SDK-normalized options are used as supplied by Foundation Models.

For structured output, import `FoundationModels`, declare an `@Generable` type, and call `respond(to:generating:)` or `respondDetailed(to:generating:)`. The schema participates in local token counting. [AppleGenerator](AppleExamples/AppleGenerator.swift) is a compiled structured-output example.

The adapter supports text, structured output and streaming with fresh sessions, without tools or shared conversation histories. Its local token count is a routing size measure, not a claim about the PCC tokenizer. PCC enforces its own context limit; native context errors remain visible. Cloud-required requests skip local tokenization entirely. If local tokenization is unavailable or fails recoverably, a permitted cloud request can proceed without local calibration; the adapter does not invent an input token count for training.

Workload names select fixed-length, hashed cache-directory names within an app-specific namespace. The adapter automatically resets calibration when instructions, schema, generation options, app build or model identity change. Supply a stable `modelIdentifier` for custom model objects to retain their calibration between launches; opaque custom models otherwise receive a fresh identity. Keep one owner per workload/cache root. Customize `cacheRoot`, `localModel`, `cloudModel` and `shouldFallback` at initialization when needed.

Automatic requests use paired calibration by default: the selected provider supplies the answer while a bounded background call measures the alternative on the same prompt. Initially, cloud supplies the answer until both providers have enough comparable observations. Secondary text and streaming snapshots stay hidden. A recoverable foreground failure can reuse the secondary call for fallback, without invoking that provider twice.

## Presets and overrides

- `.fastest` is the default: three samples per lane, zero minimum saving and zero variability penalty. It selects the lower weighted latency; exact ties retain cloud.
- `.balanced` explicitly opts into a 350 ms/25% local-saving requirement and a one-deviation timing allowance.
- `.qualityFirst` requires five samples per lane, at least 750 ms/40% local savings, and a 1.5-deviation allowance.
- `.latencyFirst` requires three samples, at least 100 ms/10% local savings, and a 0.5-deviation allowance.

Presets tune latency policy; they do not measure output quality or relax `.cloudRequired`. Override any setting while retaining the rest of a preset:

```swift
let configuration = RoutingConfiguration(
    customizing: .qualityFirst,
    localResponseReserve: 768,
    failureBackoff: 120,
    cloudRetryInterval: 300,
    calibration: .paired(refreshEvery: 1, timeout: .seconds(30))
)
```

After initial learning, `refreshEvery` schedules an alternative-model probe every N eligible requests. Missing, expired or stale comparable evidence triggers earlier probing. Each router permits at most one owned secondary call at a time. The probe timeout is also capped by the originating request's remaining deadline. Foreground success does not wait for the probe; cancellation, failure, reset and connection/model changes invalidate owned probes. `isCalibrating`, `lastCalibrationAttempt`, `waitForCalibration()` and `cancelCalibration()` expose background lifecycle separately from foreground attempt diagnostics. Stop calibration when the app suspends or leaves the workload if continued background work is inappropriate. Providers that ignore cancellation may continue their underlying work, but their abandoned output cannot train the router.

Paired calls consume additional local compute and cloud quota; measurements reflect concurrent inference conditions. Provider closures must be safe to execute for calibration without committing tool calls, purchases or other side effects. Choose `calibration: .singleProvider` to retain the original one-provider exploration policy. Hard `.localOnly` and `.cloudRequired` requests never start an alternative-provider probe. Timing calibration does not evaluate output quality: use automatic routing only where either model is suitable, and require cloud explicitly for tasks that depend on its capabilities.

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

The Apple adapter checks native model availability and PCC quota status, tokenizes local requests and applies session generation options. Custom providers supply their own availability/quota state and capacity checks. PCC still requires the appropriate entitlement and signing profile in the consuming app. The package does not provision access or supply an API key.

## Provider call budgets

Each request dispatches a given provider at most once, counting foreground generation, secondary calibration and fallback together. A fallback reuses its already-running secondary call. Neither route previews nor profile inspection start inference.

| Request | Cloud operations | Local operations |
|---|---:|---:|
| `.localOnly` | 0 | At most 1 |
| `.cloudRequired` | At most 1 | 0 |
| Automatic, initial paired learning | At most 1 | At most 1 |
| Automatic, calibrated and no probe due | Selected provider, plus at most one permitted recovery on the other provider | Same bound |
| Automatic, probe due | At most 1 | At most 1 |

Cold paired learning normally calls both providers on three comparable requests (five with quality-first). After learning, each eligible cloud-selected request can recheck local inference by default, trading extra device compute for faster quota-saving adaptation. A local-winning workload can make a cloud calibration call only after a minimum 600 seconds since its last cloud use (`cloudRetryInterval`). Failed, timed-out and standalone measured cloud calls also start that cooldown; missing evidence cannot bypass it. The timestamp is persisted before dispatch and survives normal disk-backed restarts and calibration identity changes. These probes consume provider quota even though their output is hidden. Stable workload names, retaining the router, and disk persistence avoid unnecessary repeated cold starts. Schema, instructions, model/build or OS changes can legitimately invalidate timing calibration while retaining the cloud-use cooldown. Memory-only histories restart with their owner.

Default fastest paired routing confirms mixed evidence before a paid promotion: when either of the latest two completed comparable pairs found local faster, the latest `minimumSamples` local observations must all be slower than the latest cloud timing. This avoids promoting on an isolated local spike; a decisive cloud probe can still promote immediately. Completed pairs retain numeric comparison metadata through cache reloads and local-history pruning. `conserveCloudQuota: false` opts out of this confirmation. Predictions cannot guarantee the fastest future response, and a genuine slowdown may require additional local observations before switching.

By default, `conserveCloudQuota: true` excludes PCC from automatic requests when Apple's SDK reports an approaching limit. Exhausted quota excludes PCC under every policy. Explicit `.cloudRequired` requests can use approaching-limit quota; setting `conserveCloudQuota: false` also opts automatic foreground requests into that use. Optional cloud calibration never runs near the limit. The adapter rechecks quota after asynchronous tokenization and immediately before cloud dispatch. A declined dispatch does not count as a provider failure.

The SDK exposes quota pressure, not an exact remaining request/token balance. These controls cannot reserve quota shared with other apps or impose an app-wide budget across independent routers. Custom providers report pressure through `RoutingAvailability(cloudQuota:)`; `.unknown` means no quota information was supplied.

`calibration: .singleProvider` disables secondary calibration calls, while retaining one-provider exploration and permitted fallback. Use `.localOnly` to prohibit cloud calls: `.automatic` can still try cloud after a recoverable local failure even if the last observed connection was offline. A connection observation is not a spending policy.

One secondary operation is owned per router. Apple streams and custom `streamOwned`/`RoutingProviderStream` sources retain that slot until actual producer exit, including ignored cancellation. Bare `AsyncThrowingStream` sources supplied to the legacy core `stream` API remain responsible for their own external producer cancellation. See the [stream ownership guide](Sources/AdaptiveModelRouting/AdaptiveModelRouting.docc/StreamingResponses.md).

These bounds apply to router-dispatched operations. Provider SDK retries, remote work continuing after transport cancellation, token prices, and the app's foreground request rate need app/provider budget controls. Foreground `attempts` exclude secondary work; account for calibration through provider instrumentation and `lastCalibrationAttempt`. There is no built-in currency/token spending cap. The [cost-safety verification contract](docs/COST_SAFETY.md) records the tested boundaries and qualification limits.

## Quality requirements and errors

Use `policy: .localOnly` for requests that must stay on device. It never attempts cloud generation or cloud recovery, and the Apple adapter skips PCC readiness and quota checks. If local inference is unavailable or the request exceeds its capacity, the result reports that condition. Native local tokenization errors still propagate when they cannot be recovered without cloud access.

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

## Deadlines and streaming

Requests have a **60-second overall deadline** by default, covering adapter preflight, generation and any fallback. Override it with `deadline: .after(.seconds(15))`, set the configuration's `requestDeadline`, or explicitly choose `.unlimited`. Expiry throws `RoutingRequestError.deadlineExceeded` and reports a `.timedOut` attempt if a provider was running. Expiry never starts fallback.

The router returns promptly when an asynchronous provider ignores cancellation, discards its late output and prevents late timing updates. Providers should still cooperate with task cancellation: the router cannot stop remote work or interrupt synchronous code that blocks the main actor.

```swift
let task = Task { @MainActor in
    for try await event in router.stream(to: transcript, deadline: .after(.seconds(15))) {
        switch event {
        case .selected(let decision): print(decision.reason.rawValue)
        case .update(let text, let route): render(text, from: route)
        case .completed(let result): print(result.attempts)
        }
    }
}
// Cancel this task to stop consuming and request provider cancellation.
task.cancel()
```

Updates are cumulative snapshots, so replace the displayed response instead of appending. Slow consumers may skip intermediate snapshots; the completed result retains the final snapshot. Fallback is allowed only before the first published update. An error after partial output terminates the stream without switching models. Structured streaming uses `stream(to:generating:)` with a `Sendable` partially generated type. The core router also accepts provider stream closures.

## Learning and recovery

- With both providers uncalibrated, initially answers from cloud while collecting comparable timings for both providers. Once calibrated, the default selects the lowest predicted latency without assuming cloud output is better.
- Initially runs both providers on eligible automatic requests until each has enough comparable observations: three per lane for fastest/balanced/latency-first and five for quality-first. In the usual sequential case this takes three or five completed paired requests. Cloud answers are returned while local lacks enough evidence; a qualified local lane can serve while cloud is being revalidated. Secondary output is discarded unless needed for permitted fallback.
- With native network monitoring, optional paid startup calibration waits for one successful admitted local observation and initial accepted connection state. A newer explicit known connection also satisfies readiness. The foreground answer, required cloud work and failure recovery remain available. Deferred requests consume neither PCC cooldown nor probe cadence, and no startup timer is added. Calibration continues on a subsequent eligible request.
- With zero saving margins and zero variability allowance (the default fastest configuration), a newly faster local observation can start foreground local learning before stale weighted timings would switch. Each permission is consumed and persisted before execution; failures and cancellation cannot replay it. These calls answer the request locally and leave PCC's cooldown untouched. Cloud-favoring presets keep their existing policy.
- After a network reset, qualified local timings keep serving while cloud evidence is missing. Optional PCC probes remain at least 10 minutes apart by default. If a completed current, comparable cloud observation beats both the qualified local prediction and its latest comparable observation, it permits one foreground cloud learning attempt. Each successful admitted cloud result can permit the next until three observations qualify the comparison. Failed, cancelled, unavailable or timed-out attempts cannot reuse the consumed observation, including after ordinary relaunch. These learning calls answer real requests rather than adding hidden PCC calls. Hard policies and failure recovery retain precedence.
- By default, compares at least three recent observations per lane within 25% of input size and expected output size, weighting recent measurements more heavily. Unspecified output sizes match only other unspecified sizes. Presets and overrides can change these limits.
- Separates fresh and reused sessions for each provider using `RoutingWorkload(localSession:cloudSession:)`. Keep separate routers for tasks with materially different prompts or generation settings; metadata is supplied by the caller, not inferred from model contents.
- Reports weighted timing spread. Optional presets can subtract a variability allowance from cloud latency and add it to local latency; the default fastest policy applies no variability penalty. These allowances are heuristics, not quality evaluations or statistical confidence guarantees.
- By default, any lower predicted latency can win after sufficient calibration. Explicit `.balanced` and `.qualityFirst` presets retain configurable cloud-favoring margins. Hard request policies, availability, local context capacity and failure backoff still take precedence.
- Separates cloud history by Wi-Fi, cellular, wired/other, and expensive/constrained path flags. Local timings remain device-specific across connections.
- Backs off for 60 seconds after a recoverable failure. By default it considers the alternative on every eligible request, subject to provider eligibility and quota pacing. Explicit paired refresh counts remain configurable. Cloud calibration also requires 600 seconds since the latest cloud use, including failed attempts; local refresh uses a 30-minute evidence age. Probes run only when app requests arrive. In single-provider mode these refreshes use a foreground request instead.
- Marks cloud requests still pending after the configured slow limit (20 seconds by default) for health backoff. This watch is separate from the overall request deadline.

Use `PerformanceProfile` directly for deterministic policy decisions, `InferenceExecutor` for fallback execution alone, or `AdaptiveRouter` for integrated observation, persistence and execution. `monitorConnection: false` and `updateConnection` support deterministic testing or caller-owned network observation.

## Local data

Prediction weights decay by both observation rank and elapsed time (`predictionHalfLife`, default 300 seconds), so an old fast result does not dominate fresh measurements. The small-window selector keeps stable timestamp ordering without sorting the whole history. History retains at most 128 timings per provider (256 total), so frequent requests to one provider cannot evict the other provider's calibration. Prediction sample limits and minimums cannot exceed 128.

The bounded, backup-excluded cache contains cloud-use and local-learning timestamps and route, input token count, expected output token count, session-reuse flags, elapsed time, timestamp, coarse path flags, OS version and an optional opaque calibration-identity digest. It stores no prompts, outputs, meeting questions, SSIDs, IP addresses or account identifiers. Older caches without workload metadata remain readable as fresh sessions with unspecified output size. iPhone cache files use protection until first authentication. OS updates reset calibration, and unreadable caches are preserved instead of overwritten. There is no built-in telemetry or calibration server.

Additional offline lifecycle coverage and its limits are recorded in [Simulated production coverage](docs/SIMULATED_PRODUCTION_COVERAGE.md).

Apple quota and rate-limit errors with an explicit reset date block router-managed cloud requests until that date, even when the normal retry interval expires sooner. The longest known deadline survives connection changes, calibration identity changes and disk-backed restarts. An active deadline also survives `resetProfile()` through minimal retry metadata; explicit cloud-required requests and local-failure recovery cannot bypass it. Errors without a reset date retain the normal failure backoff and paid-probe pacing. Independent router owners do not coordinate their quota state.

Initialize either router with `persistence: .memoryOnly` to avoid reading or writing calibration files. `setPersistence(.memoryOnly)` removes its existing cache by default; `resetProfile()` clears learned timings and health backoff. In-flight requests cannot repopulate a reset profile. Inspect `storageStatus` to distinguish memory-only operation, successful persistence and storage errors without failing inference. The core's `updateCalibrationIdentifier(_:)` supports caller-owned model or workload versioning.

Default storage is isolated by app bundle identifier (or executable path for command-line tools). Previous shared default caches remain untouched; the new namespace starts fresh. Explicit cache directories retain their existing behavior.

The app controls what its inference closures send to a cloud provider. Use one owner per cache directory; sharing a directory between multiple router instances or processes is not supported.

## Verify

```sh
python3 scripts/validate.py
```

The validator runs Debug and Release tests, the Release build, a separate single-import consumer, sample tests, an iOS 26 deployment-target build, documentation coverage and a warning-free DocC build. It saves logs and a summary under `.build/validation`. GitHub Actions runs the same checks on an Xcode 27 runner. See [CONTRIBUTING.md](CONTRIBUTING.md) for focused commands.

Tests use injected timings, provider closures and Apple backend operations, require no cloud entitlement, and make no model requests. They cover policies, deadlines, streaming, late cancellation, profile lifecycle, presets, diagnostics, connection differences, recovery, persistence, native error classification and Generable decoding. Both examples compile. The consumer fixture verifies one product and one import, including streaming. Actual tokenization, generation quality, signed PCC access and live network handoff remain deferred qualification work; this change does not publish a release.

## Try the sample and documentation

```sh
swift run --package-path Demo RoutingDemo
```

The [native sample](Demo/README.md) starts with simulated providers and local-only routing. Its Advanced controls expose presets, deadlines, cloud faults, attempt diagnostics and profile storage. Apple mode is opt-in and requires a suitable device and signed consuming app for PCC access.

Open the package in Xcode and choose **Build Documentation**, or open `.build/validation/AdaptiveModelRouting.doccarchive` after validation. The DocC guides cover [getting started](Sources/AdaptiveModelRouting/AdaptiveModelRouting.docc/GettingStarted.md), [policies and deadlines](Sources/AdaptiveModelRouting/AdaptiveModelRouting.docc/PoliciesAndDeadlines.md), [streaming](Sources/AdaptiveModelRouting/AdaptiveModelRouting.docc/StreamingResponses.md) and [calibration storage](Sources/AdaptiveModelRouting/AdaptiveModelRouting.docc/CalibrationAndStorage.md).

## License

MIT. See [LICENSE](LICENSE).
