# Routing Demo

A native macOS 27 sample with a simple prompt → Run → response flow. Advanced controls expose routing presets, deadlines, simulated cloud faults, diagnostics and profile storage.

```sh
swift run --package-path Demo RoutingDemo
```

Launch with an Xcode 27 SDK selected. The default **Simulated / Local only** mode makes no model requests and stores calibration only in memory. Choose Automatic and expand Advanced to try a cloud failure before output (local fallback), a failure after partial output (no provider switch), or a stalled request (deadline).

Cancel stops the consuming task and preserves visible partial output. Reset selected profile clears calibration and failure backoff. Disk storage is opt-in and saves only routing metadata for the selected demo mode.

The Apple models option uses the real package adapter. It requires supported Apple Intelligence readiness and appropriate app signing; PCC additionally needs the approved managed entitlement. A `swift run` fixture session is not proof of signed native/PCC availability. No native provider calls are made by the sample tests or normal validation command.

```sh
swift test --package-path Demo
```

The sample has one package dependency, `AdaptiveModelRouting`. Its internal support target lets the app's asynchronous state flow be tested without opening a GUI.
