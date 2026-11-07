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

Apple-model mode is an explicit choice and still depends on your device, SDK and signing/entitlement setup. Automated validation and the checked sample flow use simulations; they do not qualify live model tokenization, native generation, PCC access or network handoff.
