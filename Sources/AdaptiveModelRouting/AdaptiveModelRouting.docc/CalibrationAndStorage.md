# Calibration and storage

Control learned timings without retaining inference content.

## Automatic paired learning

When both providers are eligible and lack timings, automatic routing initially selects cloud. It can run the same request locally to learn how the two providers compare. Use this policy for workloads where either model can produce an acceptable answer.

Only the selected provider publishes text or streaming snapshots. The secondary provider runs concurrently, and its output is discarded after calibration unless a recoverable foreground failure needs that existing call for fallback. Foreground success does not wait for secondary completion. Secondary timings and outcomes appear in `lastCalibrationAttempt`, independently of foreground `attempts` and `onAttempt` callbacks.

```swift
let router = FoundationModelsRouter(
    workload: "summaries",
    configuration: .init(
        calibration: .paired(refreshEvery: 10, timeout: .seconds(30))
    )
)
let answer = try await router.respond(to: prompt)
print(router.isCalibrating)
// Call when the app leaves this workload or suspends:
router.cancelCalibration()
```

## Choose a preset

Presets control how much faster local inference must be before the router prefers it. The absolute and percentage savings must both be met. The variability allowance accounts for the spread of recent timings on each provider.

| Preset | Minimum samples per provider | Minimum local saving | Variability allowance |
| --- | ---: | --- | ---: |
| `.fastest` (default) | 3 | Any predicted advantage | 0 |
| `.balanced` | 3 | 350 ms and 25% | 1 standard deviation |
| `.latencyFirst` | 3 | 100 ms and 10% | 0.5 standard deviations |
| `.qualityFirst` | 5 | 750 ms and 40% | 1.5 standard deviations |

By default, observations are comparable when input and expected output sizes are within 25% and the provider’s session state matches (fresh or reused). An unspecified output size matches another unspecified size. The router keeps up to 128 timings per provider and uses up to six recent comparable observations for each default prediction. Cloud estimates use timings from the current connection. The device can reuse its local timings across networks.

To change an individual setting while retaining the other preset values:

```swift
let configuration = RoutingConfiguration(
    customizing: .qualityFirst,
    localResponseReserve: 768,
    failureBackoff: 120,
    calibration: .paired(refreshEvery: 1, timeout: .seconds(30))
)
```

## Refresh timing estimates

The default local refresh age is 30 minutes. A recoverable failure triggers 60 seconds of health backoff by default. A pending cloud request can trigger backoff after 20 seconds, independently of the overall request deadline.

After learning, each eligible cloud-selected request can recheck local inference by default. This adds device compute to reduce paid adaptation lag. Explicit paired refresh counts remain configurable; missing or stale comparable samples can probe sooner. Optional cloud probes also require at least `cloudRetryInterval` (600 seconds by default) since any cloud use, including failed, cancelled, timed-out and standalone measured calls. This cooldown is persisted before dispatch and survives disk-backed restarts and timing identity changes. Local probes need no cloud cooldown. Predictions weight elapsed measurement age with `predictionHalfLife` (300 seconds by default), in addition to recency rank. Rechecks run when requests arrive, without a separate repeating timer. A router owns at most one secondary call at a time. The secondary timeout is capped by the originating request's remaining deadline, including preflight. `waitForCalibration()` waits for the current probe's completion, timeout or cancellation. If a provider ignores cancellation, `isCalibrating` stays true and reserves the secondary slot until that provider actually exits. Discarded late results never train the profile.

Cloud-required, local-only, offline, unavailable, oversized and provider-backoff conditions restrict secondary execution as well as foreground inference. Cancellation or foreground failure cancels its secondary call. Profile resets, storage transitions, connection changes and calibration-identity changes cancel optional probes and invalidate obsolete training. Once a secondary is being awaited as foreground recovery, unrelated requests and calibration cancellation preserve it; the originating request can still cancel its own work.

Apple quota and rate-limit errors with an explicit reset date block router-managed cloud requests until that date, even when the normal retry interval expires sooner. The longest known deadline survives connection changes, calibration identity changes and disk-backed restarts. An active deadline also survives `resetProfile()` through minimal retry metadata; explicit cloud-required requests and local-failure recovery cannot bypass it. Errors without a reset date retain the normal failure backoff and paid-probe pacing. Independent router owners do not coordinate their quota state.

Paired requests spend additional device compute and cloud quota, and the measured speed includes concurrent inference conditions. Use `calibration: .singleProvider` for providers whose calls can commit external side effects, or to retain the original one-provider exploration behavior. That mode periodically returns local calibration answers as part of normal traffic.

## Startup and connection changes

For a newly monitored owner, optional paid cloud probes wait for an admitted live local result and an accepted initial connection observation. A newer explicit known connection can supply that state when it supersedes a queued native callback; unknown or stale observations cannot. This startup guard does not delay foreground inference, required cloud work, local shadow work or recovery. Deferred requests do not consume probe cadence or record cloud use. There is no settling timer; later eligible app requests continue calibration after readiness is established.

When local has enough comparable timings but cloud does not, paired mode serves local with `insufficientEvidence` and a local estimate only, until a successful current cloud observation beats both the qualified local prediction and its latest comparable observation. That observation permits one foreground cloud learning attempt, still reported as `insufficientEvidence` without a qualified cloud estimate. A newly admitted successful result can permit the next request until the configured minimum is reached. With default settings this normally needs one due PCC probe and up to two successful foreground learning calls, rather than three spaced probes.

The router consumes and persists that permission before yielding or emitting selection callbacks. Failed, cancelled, timed-out, unavailable and invalidated work cannot reuse it. Optional PCC probes retain the 600-second cooldown, including conservative foreground-learning reservations that never reach provider dispatch. A slower cloud observation keeps requests local and learning paced. Pure previews consume no permission. These guarantees apply to one retained router owner and its ordinary disk-backed relaunch; multiple independent owners sharing a cache do not coordinate admission.

Equal native paths retain history. Every unequal native state advances request generation and rejects obsolete in-flight cloud observations. Observable route, connectivity, capability and cost changes invalidate matching cloud timings; opaque inequalities and link-quality-only reassessments retain historical predictions as priors. They are revalidated by subsequent successful cloud work or the next eligible paid probe. An unexposed genuine network change can therefore retain an older prediction until revalidation; public fields cannot prove transport equivalence. Explicit app invalidation still clears matching history. Further changes, sparse traffic, failures, clock adjustments and quota pressure can delay qualification. Observations must remain comparable and fit within `sampleLifetime`. Hard policies, provider availability, context limits, failure recovery and single-provider exploration retain precedence. Exploration based on partial evidence is not a qualified prediction that cloud will be fastest on the next request.

## Switching between providers

With the default zero-margin, zero-variability configuration, a newly faster local observation can also permit foreground local learning while older weighted timings still favor cloud. These decisions use `localCalibration` and retain the qualified estimates: this is explicit exploration, not a claim that the weighted local prediction has already won. Permission is consumed and persisted before callbacks or suspension; only a successful admitted local result can reopen it. Failed, cancelled and timed-out attempts cannot replay the observation. This accelerates cloud-to-local adaptation without spending additional PCC calls or changing its cooldown. Balanced, quality-first, latency-first and other nonzero-margin/variability configurations retain their existing comparison policy.

The optional `lastLocalLearning` timestamp extends the existing cache format; older caches remain readable. As with cloud permission, this is single-owner coordination and ordinary successful disk-backed relaunch behavior, not an app-wide numeric quota reservation.

With quota conservation enabled, the default fastest paired mode also confirms weak paid promotions. If either of the last two completed comparable pairs found local faster, a weighted cloud preference first needs `minimumSamples` consecutive recent local observations slower than the latest cloud timing. An isolated local spike therefore earns free local confirmation instead of a new PCC call. A clearly faster cloud probe that beats all those observations can promote immediately. Two recent cloud-winning pairs also permit normal cloud selection. Failed or incomplete pairs supply no matched evidence. This confirmation does not change explicit policies, provider availability, context limits, health backoff, or cloud probe pacing.

Each completed pair retains a random comparison identifier and its matched local duration on the cloud sample. These optional numeric cache fields preserve old-cache compatibility and survive local sample pruning. Setting `conserveCloudQuota: false` disables this additional confirmation; `singleProvider` and presets with explicit local-saving margins retain their existing selection rules. Latency predictions cannot guarantee the fastest future response, and confirmation can delay a switch during a real slowdown by up to the configured local sample count.

## Conserve PCC quota

The Apple adapter reads the SDK's quota pressure status. With `conserveCloudQuota: true` (the default), automatic requests use local inference when quota is approaching its limit. Exhausted quota disables cloud for every policy. Explicit `.cloudRequired` requests can still use approaching-limit quota. Setting `conserveCloudQuota: false` opts automatic foreground work into approaching-limit use; optional cloud probes remain disabled near the limit.

Quota is checked again after asynchronous tokenization and before cloud dispatch. Declining work at that check does not create a failed-provider timing or health backoff. Custom providers pass `RoutingAvailability(cloudQuota:)`; unknown means no status was supplied.

The SDK exposes pressure flags rather than an exact remaining balance. The cooldown is per router/workload and does not reserve shared quota against other apps or rate-limit foreground cloud traffic. A prediction cannot guarantee the next provider's actual latency without running both: less frequent cloud probing conserves quota but delays discovery when cloud gets faster.

## Choose persistence

```swift
let router = FoundationModelsRouter(workload: "summaries", persistence: .memoryOnly)
let output = try await router.respond(to: prompt, policy: .localOnly)

try router.setPersistence(.disk)
print(router.storageStatus)
try router.resetProfile()
try router.setPersistence(.memoryOnly)
```

Memory-only initialization never loads or writes a calibration file. Switching to memory-only storage removes the owned file by default; pass `clearExistingCache: false` to preserve it explicitly. Reenabling disk preserves unreadable or unsupported caches rather than overwriting them. An explicit reset clears learned timings. In disk mode it replaces the cache with pacing metadata if a server retry deadline is active. Otherwise it removes the owned metadata file. The current owner retains its in-memory cloud-use cooldown; explicit cache removal means a later new owner cannot restore that timestamp.

Reset rejects a directory at the reserved `latency.json` path and preserves its contents. It also preserves unrelated sibling files. Requests already in flight can still return their outputs, but their old measurements cannot repopulate a reset profile.

Storage failures are optional calibration failures, not inference failures. Inspect ``RoutingStorageStatus`` to distinguish memory-only, persisted, unavailable and preserved-cache states.

## Invalidate changed work

The Apple adapter derives an opaque calibration identity from instructions, generation settings, response schema, model identity and app version. It installs that identity atomically with routing selection after asynchronous preflight. Interleaving text and structured requests cannot train one another's active calibration.

OS changes also invalidate calibration. Default SDK models reuse their known identity. Opaque custom model instances are isolated by default; supply a stable `modelIdentifier` that you change with your custom model version when you want profile reuse across adapter instances. The SDK does not expose every possible model update as a stable public version, so use an explicit identifier when your model lifecycle needs stronger control.

For provider closures, pass `calibrationIdentifier:` when constructing ``AdaptiveRouter`` or call `updateCalibrationIdentifier` when your own provider changes. The identifier is hashed before persistence. Without an explicit identifier at initialization, the core restores the cache's existing identity. The Apple adapter then checks it against the prepared request before using its timings, so stable workloads keep their calibration across launches and changed workloads start fresh.

## Stored metadata

The backup-excluded cache holds the most recent cloud-use timestamp and bounded provider timing samples, input and expected-output token counts, session flags, coarse network flags, timestamps, OS version and an opaque identity digest. It does not hold prompts, generated output, raw instructions, raw model identifiers or raw provider errors. No built-in telemetry is sent.

Default cache directories include a hashed host-app identity, so unsandboxed apps do not accidentally share the same workload's file. Legacy shared default paths are preserved rather than deleted; they start fresh calibration under the app namespace. Explicit custom directories retain their caller-owned location.

Keep one owner per workload/cache directory. Use separate workload names for unrelated tasks and generation patterns.
