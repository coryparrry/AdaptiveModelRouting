#!/usr/bin/env python3
"""Run the package's offline launch checks and collect concise, attributable evidence."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

if __package__:
    from .process_groups import stop_process
else:
    from process_groups import stop_process


ROOT = Path(__file__).resolve().parents[1]


def failure_excerpt(lines: list[str]) -> str:
    """Keep early attributed errors as well as the tail when artifact storage is unavailable."""
    tail_start = max(0, len(lines) - 35)
    failures = [line for line in lines[:tail_start]
                if re.search(r"error:|\bfailed\b|\b[1-9]\d* failures?\b|exceeded", line, re.IGNORECASE)]
    return "\n".join(failures[:20] + lines[tail_start:])


def write_summary(artifacts: Path, results: list, status: str, error: str = "", exit_code: int | None = None) -> None:
    """Atomically report current-run state while preserving completed summaries' list of stage records."""
    records = list(results)
    if status == "failed" and records and records[-1]["exitCode"] != 0:
        records[-1] = dict(records[-1], status=status)
    elif status != "passed":
        records.append({"step": "validation", "status": status, "exitCode": exit_code, "detail": error})
    temporary = artifacts / f".summary-{os.getpid()}.tmp"
    temporary.write_text(json.dumps(records, indent=2) + "\n")
    temporary.replace(artifacts / "summary.json")


def run_step(name: str, command: list[str], artifacts: Path, environment: dict, results: list, timeout: float = 600) -> None:
    """Save full output while reporting one completion line and bounded failure details."""
    started = time.monotonic()
    log = artifacts / f"{name}.log"
    print(f"{name}: running (log: {log.name})", flush=True)
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop_process(process)
            code = 124
            output.write(f"\nValidation step exceeded {timeout} seconds.\n")
        except BaseException:
            stop_process(process)
            raise
    record = {"step": name, "command": command, "exitCode": code,
              "seconds": round(time.monotonic() - started, 2), "log": log.name}
    results.append(record)
    write_summary(artifacts, results, "failed" if code else "running")
    print(f"{name}: {'passed' if code == 0 else 'FAILED'} ({record['seconds']}s)", flush=True)
    if code:
        print(failure_excerpt(log.read_text(errors="replace").splitlines()))
        raise SystemExit(code)


def main() -> None:
    """Validate tests, real consumer compilation, sample flows, SDK availability and DocC without provider calls."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, default=ROOT / ".build" / "validation")
    parser.add_argument("--configuration", choices=["all", "debug", "release"], default="all")
    parser.add_argument("--skip-demo", action="store_true")
    parser.add_argument("--skip-docs", action="store_true")
    parser.add_argument("--skip-ios", action="store_true")
    args = parser.parse_args()
    artifacts = args.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    # Keep a stable lock inode across runs. Closing the descriptor also releases it after interruption.
    with (artifacts / ".validation.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"Waiting for active validation in {artifacts}", flush=True)
            fcntl.flock(lock, fcntl.LOCK_EX)
        run_validation(args, artifacts)


def run_validation(args: argparse.Namespace, artifacts: Path) -> None:
    """Publish the complete run while holding exclusive use of its evidence directory."""
    results = []
    write_summary(artifacts, results, "running")
    try:
        validate(args, artifacts, results)
    except BaseException as error:
        interrupted = isinstance(error, KeyboardInterrupt) or (
            isinstance(error, SystemExit) and error.code == 128 + signal.SIGTERM)
        exit_code = 130 if isinstance(error, KeyboardInterrupt) else 1
        if isinstance(error, SystemExit) and isinstance(error.code, int):
            exit_code = error.code
        write_summary(artifacts, results, "interrupted" if interrupted else "failed",
                      str(error) or type(error).__name__, exit_code)
        raise
    write_summary(artifacts, results, "passed")
    print(f"All {len(results)} selected validation steps passed. Evidence: {artifacts}")


def validate(args: argparse.Namespace, artifacts: Path, results: list) -> None:
    """Run SDK preflight and the configured package checks with current-run evidence."""
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(artifacts / "clang-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(artifacts / "swift-cache")
    environment["NSUnbufferedIO"] = "YES"
    cache = ["--cache-path", str(artifacts / "spm-cache"), "--disable-sandbox"]
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
    if int(sdk.split(".")[0]) < 27:
        raise SystemExit("An Xcode 27 SDK is required; select a supported Xcode before validation.")
    run_step("documentation-coverage", [sys.executable, "scripts/check_documentation.py"], artifacts, environment, results)
    run_step("script-tests", [sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests"], artifacts, environment, results)
    configurations = ["debug", "release"] if args.configuration == "all" else [args.configuration]
    for configuration in configurations:
        run_step(f"tests-{configuration}", ["swift", "test", "-c", configuration, *cache], artifacts, environment, results, timeout=180)
    run_step("release-build", ["swift", "build", "-c", "release", *cache], artifacts, environment, results)
    run_step("single-import-consumer", ["swift", "build", "--package-path", "Tests/SingleImportConsumer",
             "--scratch-path", str(artifacts / "consumer-build"), *cache], artifacts, environment, results)
    if not args.skip_demo:
        run_step("sample-tests", ["swift", "test", "--package-path", "Demo", "--scratch-path",
                 str(artifacts / "demo-build"), *cache], artifacts, environment, results)
    if not args.skip_ios:
        ios_sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        ios_build = ["swift", "build", "--triple", "arm64-apple-ios26.0", "--sdk", ios_sdk,
                     "--scratch-path", str(artifacts / "ios-build"), *cache]
        run_step("ios-availability", [*ios_build, "--target", "AdaptiveModelRouting"], artifacts, environment, results)
        run_step("ios-usage-availability", [*ios_build, "--target", "AdaptiveModelRoutingUsage", "-c", "release"],
                 artifacts, environment, results)
    if not args.skip_docs:
        symbols = artifacts / "symbols"
        symbols.mkdir(exist_ok=True)
        run_step("documentation-symbols", ["swift", "build", "--target", "AdaptiveModelRouting", *cache,
                 "-Xswiftc", "-emit-symbol-graph", "-Xswiftc", "-emit-symbol-graph-dir", "-Xswiftc", str(symbols)],
                 artifacts, environment, results)
        run_step("documentation-build", ["xcrun", "docc", "convert", "Sources/AdaptiveModelRouting/AdaptiveModelRouting.docc",
                 "--additional-symbol-graph-dir", str(symbols), "--fallback-display-name", "AdaptiveModelRouting",
                 "--fallback-bundle-identifier", "dev.adaptivemodelrouting.documentation", "--fallback-bundle-version", "1",
                 "--output-path", str(artifacts / "AdaptiveModelRouting.doccarchive"), "--warnings-as-errors"],
                 artifacts, environment, results)
        run_step("documentation-archive", [sys.executable, "-m", "zipfile", "-c",
                 str(artifacts / "AdaptiveModelRouting.doccarchive.zip"),
                 str(artifacts / "AdaptiveModelRouting.doccarchive")], artifacts, environment, results)

if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    main()
