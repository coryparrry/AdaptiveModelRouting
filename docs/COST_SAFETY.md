# Cost-safety verification contract

This contract covers router-dispatched inference operations, including secondary calibration. It does not infer a provider invoice from route choice or elapsed time. Tests use synthetic providers unless a run is explicitly marked live qualification.

## Acceptance requirements

| Boundary | Required behavior | Evidence owner |
|---|---|---|
| Default selection | After sufficient comparable observations, select the lowest weighted predicted latency; optional cloud-favoring settings require explicit selection | PresetsAndDiagnosticsTests, CostSafetyLifecycleTests |
| Hard privacy | Local-only requests never dispatch cloud, including preflight, calibration, errors and streaming | Core dispatch matrices, Apple adapter matrix |
| Required cloud | Cloud-required requests never dispatch local or local tokenization | Core dispatch matrices, Apple adapter matrix |
| Readiness/capacity | Unavailable providers and overflowing local contexts are not invoked | Dispatch matrices, WorkloadEstimationTests |
| Per-request spend | At most one dispatch/start per provider, including calibration and fallback | Exact permitted-provider sets in CostSafetyMatrixTests |
| No unexpected secondary | Single-provider requests and trained paired requests below cadence use only authorized foreground/recovery providers | CostScenario permitted/required call sets; mutation campaign |
| Continued calibration | Calibrated local-winning bursts make zero extra PCC calls across 103 requests inside the cooldown; elapsed-time probes require both cadence and cloud-use spacing | CostSafetyLifecycleTests |
| Shared quota pressure | Automatic work conserves approaching-limit quota by default; all work excludes exhausted quota; late adapter checks do not create false failures | QuotaEligibilityTests, PCCQuotaTests |
| Failed refresh pacing | Failed/timed-out probes and single-provider refresh attempts cannot trigger PCC on every request; failed-use timestamps persist | QuotaScheduleTests, QuotaPersistenceTests |
| Probe resource ownership | At most one owned secondary operation per router, held until provider-worker exit after timeout/cancellation | PairedCalibrationTests, CostOwnedStreamTests, Apple text/typed stream regressions |
| Cancellation/deadline | Return promptly; no late outputs, timing training, callbacks or new fallback after termination | RequestControlTests, PairedCalibrationTests, CostOwnedStreamTests |
| Streaming recovery | A published partial answer never changes provider; empty pre-output responses may recover once | StreamingTests, PairedStreamingTests, CostOwnedStreamTests |
| Restart/model lifecycle | Valid persisted evidence is reused; changed/reset work rejects stale training and preserves unrelated files | CostSafetyLifecycleTests, ProfileControlTests, FoundationModelsRouterTests |
| Failure policy | Recoverable provider failures classify once; refusal/invalid/unknown failures do not start fallback; cancellation bypasses classification | Dispatch matrices, RoutingPolicyTests, FoundationModelsRouterTests |
| Preview calls | Route previews and profile inspection perform no inference | CostSafetyLifecycleTests |
| Consumer API | Owned custom streams and Apple text/typed/streaming APIs compile through one product/import | Tests/SingleImportConsumer, compiled examples |

## Enumerated cases

- Text dispatch matrix: 8,640 combinations.
- Owned streaming dispatch matrix: 8,640 combinations.
- Legacy bare-stream dispatch matrix: 8,640 combinations (producer ownership remains the supplying app's responsibility).
- Apple adapter dispatch-budget matrix: 2,592 combinations across text, typed text, text streaming and typed streaming.
- Fastest timing property: 4,096 timing-vector pairs using independently calculated recency-weighted comparisons.

That is 32,608 enumerated matrix/property cases inside the XCTest suite. Quota protection adds 1,728 core text/owned/legacy-stream combinations, four-format Apple preflight/dispatch transition checks, 240 stable-selector comparisons, and seven 240-request synthetic latency/quota timelines, alongside targeted cancellation, persistence, concurrency, exact-budget and provider-error tests. Counts are scenario coverage, not a claim that every possible runtime state is enumerated.

Core matrix dimensions are request policy, calibration mode, cold/local-winning/cloud-winning evidence, independent provider readiness, online/offline connection, fitting/exact/overflowing local capacity, and success/unavailable/recoverable/permanent/cancellation outcomes. An independent foreground/result contract and exact permitted/required provider-call sets specify the expected outcome. Failures retain their scenario/index and call counts under `.build/cost-safety`.

The Apple matrix adds tokenization failures, oversized prompts and native PCC quota errors. This tests the adapter's injected SDK boundary; service readiness, actual native generation and signing are qualified separately.

## Fault-injection campaign

```sh
python3 scripts/test_cost_mutations.py
```

The runner creates a fresh isolated copy of current uncommitted source/test inputs. It runs a baseline, applies one deliberately broken guard at a time, executes its relevant tests, restores exact source bytes, and finishes with a restored baseline. Each step records a log and checkpoint. A compile error or timeout is not counted as a detected behavioral fault. Survival or invalid execution fails the campaign.

Mutations cover restored cloud bias, privacy/cloud-required escape, readiness/capacity escape, duplicate generation, quota-pressure eligibility, persisted failed-use cooldowns, final foreground/secondary quota checks, promoted foreground recovery, age-weighted adaptation, stable timestamp ties, ignored single-provider opt-out, premature/late probe cadence, worker/stream ownership release, parent cancellation, partial-output fallback and stale profile training. Results are specific to the recorded source snapshot and selected mutations; they are not an exhaustive mutation score for all code.

## Accuracy and efficiency checks

`RoutingAccuracyTests` records oracle-eligible route accuracy, latency regret, dispatch counts and detection delays in `.build/quota-accuracy`. The oracle uses actual synthetic latencies unknown to the router, independently of its prediction formula. The tests cover stationary local/cloud, separated jitter, faster cloud, local throttling, shared quota pressure and network changes. They expose the exploration trade-off rather than asserting perfect future knowledge: with the default quota cooldown, the tested cloud speedup takes 600 seconds to discover. This is a measured scenario, not a universal delay bound.

The default prediction window uses a bounded selector; 240 shuffled/tied histories and window sizes compare its output with an independent full stable sort. A repeatable 10,000-decision benchmark includes a full 256-sample history. Compare Debug/Release and instrumented/uninstrumented timings separately.

## Reproduce offline checks

```sh
swift test --enable-code-coverage
swift test --show-codecov-path --enable-code-coverage
python3 scripts/validate.py
git diff --check
```

Inspect production-source line coverage separately from documentation-comment coverage. Native Apple service bodies are intentionally not executed by unit tests. Generated/framework code and platform-specific paths can require separate evidence. A coverage percentage alone does not establish correct dispatch budgets.

## Integration and financial boundaries

Automatic paired calibration is additional model work. Initially both providers run; later an alternative provider is sampled when due or stale. Provider instrumentation must include these calls, not only the foreground result's attempts. `lastCalibrationAttempt` is the latest secondary outcome, not a complete billing ledger.

Retain one owner per workload/cache directory. Cancel owned calibration when leaving a workload or replacing its owner. Router-level secondary bounds do not rate-limit the application's foreground requests or independent routers. Memory-only owners and explicit cache removal can repeat cold-start spending. Timing identity/OS invalidation retains a restored cloud-use cooldown. No numeric remaining PCC balance or cross-app reservation is inferred from the SDK pressure flags.

Custom streaming providers should use `streamOwned` and `RoutingProviderStream`, awaiting actual SDK/transport work inside the producer. The legacy bare-stream API cannot inspect or join an app's detached task. It relies on the provider's cancellation implementation. SDK-internal retries and server work after transport cancellation remain provider-controlled even when the router dispatches only once.

`.localOnly` enforces zero cloud dispatch. `.automatic` can attempt cloud recovery after a local failure while the last observed connection is offline. `.singleProvider` disables secondary calibration, not cloud selection or fallback. Monetary/token caps, request rate limits and current provider pricing must be enforced by the consuming application/provider.

Live qualification with a synthetic prompt establishes behavior for that device, OS/SDK and connection only. It does not qualify output quality, every hardware/network combination, battery cost, provider charging/refund rules, App Store distribution or arbitrary third-party SDK implementations.
