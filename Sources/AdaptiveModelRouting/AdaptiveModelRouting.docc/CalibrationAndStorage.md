# Calibration and storage

Control learned timings without retaining inference content.

## Choose persistence

```swift
let router = FoundationModelsRouter(workload: "summaries", persistence: .memoryOnly)
let output = try await router.respond(to: prompt, policy: .localOnly)

try router.setPersistence(.disk)
print(router.storageStatus)
try router.resetProfile()
try router.setPersistence(.memoryOnly)
```

Memory-only initialization never loads or writes a calibration file. Switching to memory-only storage removes the owned file by default; pass `clearExistingCache: false` to preserve it explicitly. Reenabling disk preserves unreadable or unsupported caches rather than overwriting them. An explicit reset clears memory and removes the owned metadata file when disk mode is active.

Reset rejects a directory at the reserved `latency.json` path and preserves its contents. It also preserves unrelated sibling files. Requests already in flight can still return their outputs, but their old measurements cannot repopulate a reset profile.

Storage failures are optional calibration failures, not inference failures. Inspect ``RoutingStorageStatus`` to distinguish memory-only, persisted, unavailable and preserved-cache states.

## Invalidate changed work

The Apple adapter derives an opaque calibration identity from instructions, generation settings, response schema, model identity and app version. It installs that identity atomically with routing selection after asynchronous preflight. Interleaving text and structured requests cannot train one another's active calibration.

OS changes also invalidate calibration. Default SDK models reuse their known identity. Opaque custom model instances are isolated by default; supply a stable `modelIdentifier` that you change with your custom model version when you want profile reuse across adapter instances. The SDK does not expose every possible model update as a stable public version, so use an explicit identifier when your model lifecycle needs stronger control.

For provider closures, pass `calibrationIdentifier:` when constructing ``AdaptiveRouter`` or call `updateCalibrationIdentifier` when your own provider changes. The identifier is hashed before persistence. Without an explicit identifier at initialization, the core restores the cache's existing identity. The Apple adapter then checks it against the prepared request before using its timings, so stable workloads keep their calibration across launches and changed workloads start fresh.

## Stored metadata

The backup-excluded cache holds bounded provider timing samples, input and expected-output token counts, session flags, coarse network flags, timestamps, OS version and an opaque identity digest. It does not hold prompts, generated output, raw instructions, raw model identifiers or raw provider errors. No built-in telemetry is sent.

Default cache directories include a hashed host-app identity, so unsandboxed apps do not accidentally share the same workload's file. Legacy shared default paths are preserved rather than deleted; they start fresh calibration under the app namespace. Explicit custom directories retain their caller-owned location.

Keep one owner per workload/cache directory. Use separate workload names for unrelated tasks and generation patterns.
