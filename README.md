# AdaptiveModelRouting

AdaptiveModelRouting is a Swift package for iOS and macOS that routes language model requests between on-device and cloud models, including Apple Foundation Models and Private Cloud Compute. When both providers are allowed, it learns from measured response times and chooses the one it expects to answer faster for the request size and current connection.

- **Control where each prompt goes.** Use `.localOnly` to keep a sensitive request on the device, `.cloudRequired` for a task that needs the cloud model, or `.automatic` to let the router choose. By default, automatic calibration can send the same prompt to both providers.
- **Recover from temporary failures.** The router can try another permitted provider if a request fails. Once it publishes a streaming update, it stays with that provider. The Apple adapter also respects reset dates reported by PCC quota and Foundation Models rate-limit errors.
- **Use text, structured output, or streaming.** Use the Apple Foundation Models adapter, or bring your own local and cloud providers as Swift closures.
- **Inspect a routing decision.** Detailed results show why a provider was selected, which one answered, and how long each foreground attempt took. The router stores timing history on the device and saves no prompts or generated responses.

Build with an iOS or macOS 27 SDK. The core router supports iOS 26+ and macOS 26+. The Apple adapter requires iOS 27+ or macOS 27+. The package has no third-party dependencies.

## Add the package

For the Apple adapter and the features below, use version 0.2.0 or later. In Xcode, choose **File → Add Package Dependencies**, enter the repository URL, and select the **AdaptiveModelRouting** library. In a Swift package, add this dependency to `Package.swift`:

```swift
.package(url: "https://github.com/coryparrry/AdaptiveModelRouting.git", .upToNextMinor(from: "0.2.0"))
```

Until version 0.2.0 is published, place a checkout beside your app’s package and use a local dependency:

```swift
.package(path: "../AdaptiveModelRouting")
```

Add `.product(name: "AdaptiveModelRouting", package: "AdaptiveModelRouting")` to your target’s dependencies.

## Quick start: generate on device

On a supported device with Apple Intelligence ready, this example sends one request to the local model. It needs no PCC entitlement. In an app, keep the router in a main-actor model so it can reuse timings across requests.

```swift
import AdaptiveModelRouting

let router = FoundationModelsRouter(workload: "summaries")
let summary = try await router.respond(
    to: "Summarize this note in one sentence: The garden opens at nine on Saturday.",
    policy: .localOnly
)
print(summary)
```

**Try the demo without a model.** From the repository root on macOS 27+, run the command below. The demo opens in simulated, local-only mode. Switch to Automatic and simulate a cloud failure to see which provider answers. [Demo guide](Demo/README.md)

```sh
swift run --package-path Demo RoutingDemo
```

### Choose a policy for other requests

Use `.automatic` when either model is suitable and the prompt may go to the cloud. This is the default when you omit `policy`.

```swift
let ideas = try await router.respond(to: "Suggest three names for a public garden.", policy: .automatic)
```

Use `.cloudRequired` when the task needs cloud capabilities. The Apple adapter requires your app to have Apple’s managed PCC entitlement and appropriate signing. If PCC is unavailable, this call throws.

```swift
let outline = try await router.respond(to: "Outline a citywide tree-planting plan.", policy: .cloudRequired)
```

For typed output, import `FoundationModels`, declare an `@Generable` type, and pass it to `respond(to:generating:)`. [Compiled structured-output example](AppleExamples/AppleGenerator.swift)

## Stream a response

The Apple adapter streams cumulative snapshots. In a UI, replace the displayed text on each update. Here the task runs to completion and prints the final text.

```swift
let streamTask = Task { @MainActor in
    var text = ""
    for try await event in router.stream(to: "Describe a maple leaf.", policy: .localOnly) {
        switch event {
        case .selected: break
        case .update(let snapshot, _): text = snapshot
        case .completed(let result): text = result.value ?? text
        }
    }
    print(text)
}
try await streamTask.value
```

In an app, retain the task handle. If the user taps **Cancel** while generation is running, call `streamTask.cancel()` from that action. The default 60-second deadline covers preflight, generation, and any permitted fallback. [Streaming guide](Sources/AdaptiveModelRouting/AdaptiveModelRouting.docc/StreamingResponses.md) · [Policies and deadlines](Sources/AdaptiveModelRouting/AdaptiveModelRouting.docc/PoliciesAndDeadlines.md)

## Inspect a result

Use `respondDetailed` when you need to explain a decision or handle input that requires chunking. The Apple convenience method `respond` returns a value or throws. The detailed API also reports availability, the original selection, and the outcome of each foreground attempt.

```swift
let result = try await router.respondDetailed(to: "Name a shade tree.", policy: .automatic)
print(result.decision.reason.rawValue)
print(result.route as Any)
print(result.didFallback)
print(result.attempts)
```

Secondary calibration has its own diagnostics in `lastCalibrationAttempt`. Use `onAttempt` to observe a foreground failure even when the request throws.

## Configure routing and calibration

The default `.fastest` preset learns from comparable requests. During paired calibration, both providers may process the same prompt. This uses extra device compute and can spend cloud quota. The router dispatches each provider at most once per request, including calibration and fallback.

Choose `.singleProvider` to disable secondary calls. Permitted fallback can still invoke the other provider, so make sure that retrying an operation is safe if it has side effects. To keep learned timings in memory only, initialize the router with `persistence: .memoryOnly`.

The calibration guide covers presets, sample thresholds, probe intervals, quota pressure, network changes, and storage controls. [Calibration and storage](Sources/AdaptiveModelRouting/AdaptiveModelRouting.docc/CalibrationAndStorage.md) · [Provider call budgets and tests](docs/COST_SAFETY.md)

## Use your own providers

Use `AdaptiveRouter` when your app supplies the inference operations. Keep one router and cache directory per workload. Give it the full local input token count, including instructions and schema, and the actual local context capacity.

```swift
let result: String? = try await core.respond(
    inputTokens: requestTokens,
    localContextCapacity: localModelCapacity,
    workload: .init(expectedOutputTokens: 512),
    cloud: { try await generateInCloud() },
    onDevice: { try await generateLocally() }
)
```

Here `core` is your retained `AdaptiveRouter`, and the counts and closures come from your app. Set the actual output limit in your provider. Return `nil` from the cloud closure when it is unavailable. Use `shouldFallback` to classify recoverable provider errors. [Compiled provider example](Examples/Generator.swift)

## Upgrading from 0.1.0

Automatic routing now enables paired calibration by default and selects for measured latency. To keep one-provider exploration, choose `RoutingConfiguration(calibration: .singleProvider)`. The new default deadline is 60 seconds. Wrappers that forward provider closures must accept escaping, main-actor-isolated closures.

The default disk cache now uses a per-app directory, so apps using the old default start with fresh timings. Apps that supply their own directory can reuse compatible caches.

## Verification

Run `python3 scripts/validate.py` for the Debug and Release tests, external consumer build, demo tests, iOS cross-build, and documentation checks. The automated suite uses injected providers. For dated results from the separate native macOS check and the remaining device and PCC checks, see the qualification record. [Validation and sample app](Sources/AdaptiveModelRouting/AdaptiveModelRouting.docc/ValidationAndSample.md) · [Contributing](CONTRIBUTING.md)

## License

MIT. See [LICENSE](LICENSE).
