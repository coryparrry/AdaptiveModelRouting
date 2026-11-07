# Streaming responses

Display cumulative snapshots while preserving provider identity and failure boundaries.

```swift
let task = Task { @MainActor in
    for try await event in router.stream(to: prompt, policy: .localOnly) {
        switch event {
        case .selected(let decision):
            selection = decision.reason.rawValue
        case .update(let snapshot, _):
            text = snapshot // Replace the previous snapshot; do not append it.
        case .completed(let result):
            text = result.value ?? text
            actualProvider = result.route
        }
    }
}

// Cancel this task when the view or request is no longer needed.
task.cancel()
```

## Recovery boundaries

A recoverable failure before the first published snapshot may use the other permitted provider. After the first snapshot is published, errors propagate and visible output is never silently restarted with another model. The failed provider can still receive health backoff.

An empty cloud stream is unavailable and may recover locally. An empty local stream throws ``RoutingRequestError/emptyStream``. Cloud-required and local-only constraints remain binding for streams.

## Bounded snapshots

Streams start when created. Keep the consuming task so you can cancel it. The package buffers at most eight routing events and the native bridge buffers one cumulative SDK snapshot. Fast producers can coalesce intermediate updates or the initial selection event. A `.completed` event includes the final value, original decision, actual route and complete attempt diagnostics.

Cancel the task consuming the stream to stop provider work; simply retaining an abandoned stream is not a cancellation API. The default request deadline also bounds waiting for stalled streams.

## Structured output

`stream(to:generating:)` exposes the native type's `PartiallyGenerated` snapshots when they conform to `Sendable`. Fields may be absent while generation is in progress. The final result contains the last partial representation of the completed native response. The bridge collects the original SDK stream's final response; it does not start another generation.

For a public `@Generable` type, declare checked conformance in the same source file as the type:

```swift
extension Summary.PartiallyGenerated: Sendable {}
```

The compiler verifies that its generated fields are safe to transfer. The compiled `AppleGenerator` example demonstrates this declaration.

When you need a concrete fully generated type instead of partial fields, use `respond(to:generating:)`.
