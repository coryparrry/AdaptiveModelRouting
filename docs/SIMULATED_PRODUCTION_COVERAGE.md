# Simulated production coverage — 14 November 2026

Limited-account quota, throttling, recovery and inaccessible network conditions now have additional deterministic regression coverage. This work used injected provider operations and synthetic cache timelines: **zero real model/PCC calls and no host network changes**. The cancelled physical switch to another Wi-Fi network was not resumed.

## Coverage and checks

The package now has **216 XCTest methods**, including eight added for these lifecycles. Existing dispatch matrices exercise **8,640 combinations per mode** (text, owned stream and legacy stream), and the quota-eligibility matrix exercises **1,728 combinations**. These are bounded synthetic combinations, not live users, devices or accounts.

| Scenario | Evidence |
|---|---|
| Quota warning → exhausted → available | Four Apple adapter APIs, 256 warning/exhausted foreground requests with zero cloud dispatch, then one permitted revalidation per API. No false provider-health backoff is created by quota eligibility alone. |
| Runtime quota exhaustion, rate limiting, service outage and network failure | 16 error/format sequences; one initial cloud attempt, at most one local fallback, 32 quiet requests, persisted elapsed-time replay and one recovery probe. |
| Long provider reset dates | Rate-limit and PCC quota-limit errors across four APIs. An advertised one-hour reset blocks a probe after a simulated 601 seconds; revalidation resumes after expiry. Defaults remain unchanged. |
| Reset/permission bypasses | Known provider deadlines survive network/identity/profile resets and disk-backed relaunch; hard cloud requests, unavailable local inference and local-failure recovery cannot bypass them. |
| Late provider errors | 12 format/boundary cases: an in-flight error spans a connection change, identity change or denied fallback. Its provider-wide deadline remains valid while obsolete timing/health observations are rejected. |
| Concurrent request race | A request already awaiting local work cannot dispatch cloud fallback after a second request learns a throttle deadline. |
| Network lifecycle | Nine cases: changed Wi-Fi gateway, expensive hotspot, cellular, Ethernet, offline, opaque inequality, link quality, duplicate and stale observation. Each preserves local history and paid pacing, with 27 following local requests and zero extra cloud dispatches. Destination cloud buckets are invalidated where appropriate; obsolete in-flight cloud timings are rejected. |
| Caller cancellation during handoff | Buffered and owned-stream requests using a cancellation-ignoring fake provider; no fallback, late sample or false health failure after cancellation. |
| Other conditions already covered | Startup gating, quota changes during preflight/last dispatch, unavailable or oversized providers, partial/empty streams, deadlines, non-cooperative producers, persistence/identity changes, concurrent secondary ownership, clock rollback and changing latency/noise oracles. |

## Bug found and fixed

The first valid new regression showed that a structured provider reset date was ignored: the normal ten-minute paid-probe interval could permit another cloud call before an advertised one-hour throttle expired. The router now stores the longest finite future Apple quota/rate-limit reset date as provider-wide pacing metadata, independently of network-specific timing history.

Readiness and the final dispatch boundary both enforce that deadline. It survives normal disk-backed restarts and calibration resets. An active deadline causes `resetProfile()` to retain minimal pacing metadata rather than deleting the only copy of the deadline. Errors without a reset date retain existing failure backoff and paid-probe pacing. Error descriptions and generated content are not stored.

Independent review then identified a stale-generation boundary: recording the deadline only during accepted health classification lost it after a handoff or a denied fallback. A regression reproduced that defect. Deadline capture now occurs at the cloud error boundary before cancellation, stale-generation and fallback checks; health/timing admission still retains its original guards. The scoped re-review found no remaining material issue.

## Verification results

- **Release:** all 216 tests passed. All ten selected validation steps passed, including script checks, release build, external consumer, six demo tests, iOS cross-compilation and DocC validation.
- **Debug:** the full run passed 215 tests and failed only the unchanged selector's wall-clock benchmark during substantial concurrent CPU use. Its 10,000 decisions took 8.433 seconds against the existing five-second limit. A subsequent isolated run, after this task's other build work ended, passed at 2.245 seconds without changing code or the limit. All 216 distinct Debug tests therefore have passing evidence, but the full-run benchmark failure is preserved rather than presented as an uninterrupted green run.
- **Fault injection:** four independent faults in a disposable source copy were all detected by XCTest assertions: forgetting a server deadline, bypassing the live dispatch gate, losing metadata on profile reset and losing it on a network change. Clean and restored baselines passed; real source remained unchanged.
- **Documentation coverage:** 547/547 Swift declarations and 22/22 Python declarations documented, using the project's lexical Swift and AST Python checks. This is documentation coverage, not a claim of complete branch coverage.

Full logs and source checkpoints are under `.build/simulated-production-cases/`. `validation/summary.json`, `fault-checks/summary.json`, `round3.log`, `stale-hint-regression-before-fix.log`, `baseline-fixed-harness.log` and `debug-benchmark-isolated.log` preserve per-case and before/after evidence. An initial test helper cancelled legitimate secondary work too early; that helper was corrected before the valid failing throttle baseline. Redundant build/cache directories and the disposable source copy are removed after verification; logs and summaries remain.

To rerun the persistent regression tests without any live provider use:

```sh
swift test --filter 'QuotaLifecycleSimulationTests|NetworkLifecycleSimulationTests'
python3 scripts/validate.py
```

## Limits

Simulation validates this router's decisions, dispatch budgets and reactions to supplied SDK states/errors. It does not establish Apple's actual account enforcement, billing, reset-date accuracy, physical radio behavior, thermal/battery effects, real iOS runtime behavior or arbitrary model answer quality. Prior real-model runs apply to their pinned earlier source; this throttle fix has been verified offline and has not consumed real PCC quota for another live run.

A different SSID is simulated through an observable route change such as a gateway change. An actual transport change that exposes none of the monitored public differences remains indistinguishable from an opaque reassessment; historical priors are retained for later revalidation. Physical different-network/cellular handoffs remain untested live.

Pacing guarantees are per router owner, not a global account-wide quota coordinator across independent instances/processes. Restart persistence requires usable disk storage; memory-only operation intentionally does not persist metadata. The low-level `measure` callback remains caller-managed work; the dispatch gate governs router-managed generation APIs. No finite simulated matrix proves every future provider, workload or OS condition.
