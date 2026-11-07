# Contributing

Build with an Xcode 27 SDK. Core routing APIs support iOS/macOS 26; the Apple adapter and sample require iOS/macOS 27 runtimes.

Before pushing, run:

```sh
python3 scripts/validate.py
git diff --check
```

The validation command runs the package's debug/release tests, external one-import consumer, sample model tests, iOS cross-compilation and DocC conversion. It keeps full logs and `summary.json` under `.build/validation`; inspect those logs for failures instead of repeatedly rerunning unchanged conditions. CI uses the same command on the official `xcode-27` runner image and uploads the evidence and DocC archive.

Artifact upload is best-effort: storage quota failures do not change the validation result. Stage results and bounded failure details remain in the job log.

Add regression tests for changed behavior and maintain at least 85% documentation-comment/docstring coverage. `scripts/check_documentation.py` reports lexical Swift declaration coverage and Python AST docstrings separately. Generated code and build directories are excluded.

Preserve the one-product, one-import public API. Hard provider constraints must apply during preflight, fallback, streaming and failure. Never retry after publishing partial output. Deadlines and cancellation must not permit late profile training or callbacks, and reset must preserve unrelated files.

Tests and CI use injected providers. Do not add native generation, PCC requests, signing changes, a release tag or distribution steps to the offline validation pipeline. Those are separate qualification/release decisions.
