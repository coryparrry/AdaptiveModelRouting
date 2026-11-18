# Getting started

Add one package product and retain one router for each workload.

## Install

The repository is private, so your Git or Xcode account needs read access. Add the `AdaptiveModelRouting` product to the app target and use `import AdaptiveModelRouting`. The existing `0.1.0` tag predates the current APIs; use the development branch or a reviewed commit until a new release is published.

## Use the Apple adapter

```swift
import AdaptiveModelRouting

// Retain this in an @MainActor app model.
let router = FoundationModelsRouter(
    workload: "summaries",
    instructions: "Summarize accurately and concisely.",
    configuration: .fastest
)

let output = try await router.respond(to: transcript, policy: .localOnly)
```

The adapter uses fresh provider sessions. It counts the local transcript, including instructions, framing and structured-response schemas, and reserves the actual response limit. It checks readiness and known quota exhaustion only for permitted providers. Local-only requests do not construct a PCC model or inspect its readiness or quota.

Apple's `GenerationOptions` can be supplied as `options:` to customize generation. The default maximum response is 512 tokens; an unset limit uses the configured local reserve. Native context, refusal and unknown errors remain visible.

To declare a structured model, import Apple's `FoundationModels` framework where you use its `@Generable` macro. Call `respond(to:generating:)` with that type. This does not require another package product.

## Use your own providers

``AdaptiveRouter`` accepts cloud and local closures and preserves their native error types. Count the full local input and supply the real local capacity. Providers execute on `MainActor`; asynchronous operations should suspend rather than block that actor.

``InferenceExecutor`` is the lower-level fallback-only API. Use ``AdaptiveRouter`` when you also need request deadlines, timing, storage and diagnostics.

## Understand availability

Local inference needs a supported device and ready Apple Intelligence model. PCC also requires the consuming app's approved managed entitlement and signing. This package does not provision entitlement access. A no-result error distinguishes unavailable providers from input that needs chunking.
