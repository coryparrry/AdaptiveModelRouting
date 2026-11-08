#!/usr/bin/env python3
"""Run the package's offline launch checks and collect concise, attributable evidence."""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def stop_process(process: subprocess.Popen) -> None:
    """Cancel the owned process group so timeout or interruption does not strand compiler children."""
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    except ProcessLookupError:
        process.wait()


def failure_excerpt(lines: list[str]) -> str:
    """Keep early attributed errors as well as the tail when artifact storage is unavailable."""
    tail_start = max(0, len(lines) - 35)
    failures = [line for line in lines[:tail_start]
                if re.search(r"error:|\bfailed\b|\b[1-9]\d* failures?\b|exceeded", line, re.IGNORECASE)]
    return "\n".join(failures[:20] + lines[tail_start:])


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
    (artifacts / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
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
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(artifacts / "clang-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(artifacts / "swift-cache")
    environment["NSUnbufferedIO"] = "YES"
    cache = ["--cache-path", str(artifacts / "spm-cache"), "--disable-sandbox"]
    results = []
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
        run_step("ios-availability", ["swift", "build", "--target", "AdaptiveModelRouting", "--triple", "arm64-apple-ios26.0",
                 "--sdk", ios_sdk, "--scratch-path", str(artifacts / "ios-build"), *cache], artifacts, environment, results)
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
    print(f"All {len(results)} selected validation steps passed. Evidence: {artifacts}")


if __name__ == "__main__":
    main()
