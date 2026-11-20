# Contributing

Build with an Xcode 27 SDK. Core routing APIs support iOS/macOS 26; the Apple adapter and sample require iOS/macOS 27 runtimes.

Before pushing, run:

```sh
python3 scripts/validate.py
git diff --check
```

The validation command runs the package's debug/release tests, external one-import consumer, sample model tests, iOS cross-compilation and DocC conversion. It keeps full logs and `summary.json` under `.build/validation`; inspect those logs for failures instead of repeatedly rerunning unchanged conditions. CI uses the same command on the official `xcode-27` runner image and uploads the evidence and DocC archive.

Runs using the same evidence directory wait for one another. Each run replaces the previous summary when it starts. The last entry reports `running`, `failed` or `interrupted` until validation succeeds. A successful summary contains only completed stages with exit code zero.

Artifact upload is best-effort: storage quota failures do not change the validation result. Stage results and bounded failure details remain in the job log.
The DocC archive is zipped before upload because its generated symbol filenames can contain colons that GitHub artifacts reject.

Add regression tests for changed behavior and maintain at least 85% documentation-comment/docstring coverage. `scripts/check_documentation.py` reports lexical Swift declaration coverage and Python AST docstrings separately. Generated code and build directories are excluded.

Preserve the one-product, one-import public API. Hard provider constraints must apply during preflight, fallback, streaming and failure. Never retry after publishing partial output. Deadlines and cancellation must not permit late profile training or callbacks, and reset must preserve unrelated files.

Tests and CI use injected providers. The release workflow reuses the offline validation suite and checks versioned SwiftPM installation before publishing. See the [release guide](docs/releasing.md) for staging, deployment, and separate live Apple inference checks.

Cost-sensitive verification is specified in [docs/COST_SAFETY.md](docs/COST_SAFETY.md). The normal Swift suites include dispatch matrices and lifecycle budgets. Collect compiler coverage with `swift test --enable-code-coverage`, and run `python3 scripts/test_cost_mutations.py` for isolated fault injection. The mutation runner copies current source/test inputs, checks a clean baseline, restores each mutation, and verifies a restored baseline; it never edits the working source and makes no live provider calls. It preserves logs and checkpoints under `.build`.
