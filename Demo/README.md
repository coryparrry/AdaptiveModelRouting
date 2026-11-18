# Routing Demo

A native macOS 27 sample with a simple prompt → Run → response flow. Advanced controls expose routing presets, deadlines, simulated cloud faults, diagnostics and profile storage.

```sh
./script/build_and_run.sh
```

Launch with an Xcode 27 SDK selected. The default **Simulated / Local only** mode makes no model requests and stores calibration only in memory. The selected preset defaults to Fastest, matching the package. Choose Automatic and expand Advanced to try a cloud failure before output (local fallback), a failure after partial output (no provider switch), or a stalled request (deadline).

Windows share the same request. Closing the last window or pressing Cancel stops the request and any background calibration while preserving visible output. Reset selected profile clears calibration and failure backoff. Disk storage is opt-in and saves only routing metadata for the selected demo mode. Each mode remembers its own storage choice across app launches. If you previously used the version with a shared storage toggle, opt in again for each mode you want to save. Existing profiles remain on disk. Provider and policy controls still open in safe Simulated / Local only mode.

The Apple models option uses the real package adapter. It requires supported Apple Intelligence readiness and appropriate app signing; PCC additionally needs the approved managed entitlement. A `swift run` fixture session is not proof of signed native/PCC availability. No native provider calls are made by the sample tests or normal validation command.

```sh
swift test --package-path Demo
```

The sample has one package dependency, `AdaptiveModelRouting`. Its internal support target lets the app's asynchronous state flow be tested without opening a GUI.

The run script stages a real macOS app bundle and launches it through Launch Services. Ad-hoc signing supports the simulated demo. Real PCC testing additionally requires a development identity and an approved provisioning profile; signing assets can be supplied through `ROUTING_DEMO_SIGNING_ASSETS` and `ROUTING_DEMO_SIGNING_IDENTITY`.

For content-free native call diagnostics, use `./script/build_and_run.sh --telemetry`. The `AdaptiveModelRouting` / `NativeInference` unified debug log records invocation IDs, route, format, completion and duration, without prompts or answers.
