# Validation and sample app

Run repeatable offline checks before a push, without consuming model quota.

## One validation command

From the repository root:

```sh
python3 scripts/validate.py
```

The command checks documentation coverage, debug/release tests, release compilation, the one-import consumer, sample-app model tests, iOS availability and this DocC catalog. It saves complete logs and a machine-readable summary in `.build/validation`. Failures stop the pipeline with the failing stage's log location and bounded output.

GitHub Actions runs the same command on the official `xcode-27` macOS image. Its artifacts contain validation logs and a DocC archive. The workflow does not publish a package version or release.

## Run the sample

```sh
swift run --package-path Demo RoutingDemo
```

The macOS sample defaults to simulated providers, local-only routing and memory-only calibration. Run, cancel, inspect cumulative output, and expand Advanced to choose presets, deadlines, simulated cloud failures and profile controls. Model-level tests cover recovery before output, failure after partial output, deadline expiry, cancellation and storage reset.

Apple-model mode uses the device’s model and requires a supported configuration. PCC also requires the consuming app’s managed entitlement and signing.

## Candidate qualification, 18 November 2026

The release candidate at `656d8c0` passed all 11 validation stages with Xcode 27.2 (27B52), including 234 package tests each in Debug and Release and a cross-build targeting iOS 26. In a separate native macOS check, the Apple adapter tokenized two synthetic prompts and completed one buffered and one streaming request using `.localOnly`.

Signed PCC generation in a consuming app, execution on a physical iPhone, and live network handoffs remain unverified for that revision.
