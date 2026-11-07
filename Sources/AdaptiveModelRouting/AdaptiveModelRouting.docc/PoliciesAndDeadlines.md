# Policies and deadlines

Apply hard provider constraints independently of timing preferences.

## Provider policies

| Policy | Allowed operations |
|---|---|
| `.localOnly` | Local generation only; no cloud readiness/quota inspection or fallback. |
| `.cloudRequired` | Cloud generation only; local preflight and fallback are skipped. |
| `.automatic` | Either provider, including calibration and permitted recovery. |

Presets tune latency policy and never override these constraints. `.qualityFirst` expresses a stronger cloud preference; it does not evaluate generated quality. If local quality is unacceptable for a task, use `.cloudRequired`.

## One request budget

All router requests default to a 60-second deadline spanning token counting, generation and recovery. Configure a default or override one call:

```swift
let configuration = RoutingConfiguration(
    customizing: .balanced,
    requestDeadline: .after(.seconds(30))
)

let result = try await router.respond(
    to: prompt,
    policy: .localOnly,
    deadline: .after(.seconds(10))
)
```

Use `.unlimited` explicitly to disable the budget. An invalid nonpositive deadline fails before provider work. Deadline expiry throws ``RoutingRequestError/deadlineExceeded`` and never starts another provider. An active attempt reports `.timedOut`; caller cancellation reports `.cancelled` and propagates `CancellationError`.

## Cancellation and late work

The request returns promptly when a suspended asynchronous provider ignores cancellation. Cancellation is requested for the provider task; late completions cannot publish output, add timings or fire another attempt callback. A cancelled slow-request watcher cannot later change provider health.

Swift cancellation remains cooperative: the package cannot force arbitrary native work to stop or interrupt synchronous code blocking `MainActor`. Custom providers should suspend and respond to cancellation. Returning a deadline error does not prove that a remote server stopped computation.

The separate slow-cloud threshold remains a health signal, not a second deadline. It can apply backoff before a request eventually succeeds, fails or is cancelled.
