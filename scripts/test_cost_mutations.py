#!/usr/bin/env python3
"""Prove billing-critical tests reject deliberately broken routing guards in an isolated source copy."""

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def mutations() -> list[dict]:
    """Keep mutations compilable, bounded and attributable to a named behavioral contract."""
    core = "Sources/AdaptiveModelRouting/AdaptiveRouter.swift"
    executor = "Sources/AdaptiveModelRouting/InferenceExecutor.swift"
    profile = "Sources/AdaptiveModelRouting/PerformanceProfile.swift"
    coordinator = "Sources/AdaptiveModelRouting/CalibrationRuntime.swift"
    matrix = "CostSafetyMatrixTests"
    current_profile = "if snapshot.profileGeneration == profileGeneration && (model == .onDevice || snapshot.generation == generation) {"
    current_connection = "if model == .onDevice || snapshot.generation == generation {"
    return [
        {"name": "restore-cloud-saving-bias", "filter": "PresetsAndDiagnosticsTests.testDefaultChoosesEvenASmallMeasuredAdvantage",
         "edits": [("Sources/AdaptiveModelRouting/RoutingConfiguration.swift",
                    "minimumLocalSavingSeconds: TimeInterval = 0,", "minimumLocalSavingSeconds: TimeInterval = 0.35,")]},
        {"name": "restore-cloud-variability-bias", "filter": "PresetsAndDiagnosticsTests.testDefaultDoesNotApplyACloudVariabilityPreference",
         "edits": [("Sources/AdaptiveModelRouting/RoutingConfiguration.swift",
                    "variabilityAllowance: Double = 0,", "variabilityAllowance: Double = 1,")]},
        {"name": "allow-cloud-after-local-only-failure", "filter": "RequestControlTests.testLocalOnlyNeverCallsCloud",
         "edits": [(executor, "if policy == .localOnly {", "if false && policy == .localOnly {")]},
        {"name": "allow-local-after-cloud-required-nil", "filter": "QuotaEligibilityTests.testDirectExecutorCloudRequiredNilCannotSpendLocal",
         "edits": [(executor, "guard policy != .cloudRequired, canUseLocalWhole else { return nil }",
                    "guard canUseLocalWhole else { return nil }")]},
        {"name": "ignore-local-readiness", "filter": matrix,
         "edits": [(core, "canUseLocalWhole: fits && availability.onDevice,", "canUseLocalWhole: fits,")]},
        {"name": "ignore-cloud-readiness", "filter": matrix,
         "edits": [(core, "guard availability.cloud else { return nil }", "guard true else { return nil }")]},
        {"name": "ignore-local-context-capacity", "filter": matrix,
         "edits": [(executor,
                    "inputTokens >= 0 && responseReserve >= 0 && localCapacity >= responseReserve\n            && inputTokens <= localCapacity - responseReserve",
                    "true")]},
        {"name": "duplicate-cloud-generation", "filter": matrix,
         "edits": [(core, "return try await cloud(context, false)",
                    "_ = try await cloud(context, false); return try await cloud(context, false)")]},
        {"name": "duplicate-local-generation", "filter": matrix,
         "edits": [(core, "{ try await onDevice(context, false) }",
                    "{ _ = try await onDevice(context, false); return try await onDevice(context, false) }")]},
        {"name": "change-cloud-probe-cadence", "filter": "QuotaScheduleTests.testExactCadenceAndCooldown",
         "edits": [(coordinator, "requestsSinceProbe >= frequency", "requestsSinceProbe > frequency")]},
        {"name": "probe-before-refresh-is-due", "filter": matrix,
         "edits": [(coordinator, "guard required || requestsSinceProbe >= frequency else { return false }", "guard true else { return false }")]},
        {"name": "ignore-single-provider-opt-out", "filter": matrix,
         "edits": [("Sources/AdaptiveModelRouting/RoutingConfiguration.swift", "self.calibration = calibration",
                    "self.calibration = .paired()")]},
        {"name": "release-slot-before-worker-exits", "filter": "PairedCalibrationTests.testProbeTimeoutDiscardsLateResult",
         "edits": [(coordinator, "await probe.waitForWorker()", "// deliberately omit actual worker join")]},
        {"name": "release-slot-before-stream-producer-exits", "filter": "FoundationModelsRouterTests.testStreamingProbeTimeoutRetainsActualProducerSlot",
         "edits": [("Sources/AdaptiveModelRouting/Streaming.swift",
                    "if let error = await source.finishProducer(), route == .cloud { recordRetryDeadline(error) }",
                    "// deliberately omit actual stream producer join")]},
        {"name": "leave-probe-running-after-parent-cancel", "filter": "PairedCalibrationTests.testForegroundCancellationCancelsProbe",
         "edits": [(core, "context.onAbort = { probe.cancel() }", "context.onAbort = {}") ]},
        {"name": "allow-fallback-after-partial-output", "filter": "CostOwnedStreamTests.testOwnedPartialOutputNeverSwitchesProviders",
         "edits": [("Sources/AdaptiveModelRouting/Streaming.swift", "canFallback: { !published }", "canFallback: { true }")]},
        {"name": "train-reset-profile-with-old-request", "filter": "ProfileControlTests.testResetPreservesSiblingFilesAndRejectsInflightTraining",
         "edits": [(core, current_profile + suffix, current_connection + suffix)
                   for suffix in ["\n                let accepted", "\n                    if accepted"]]},
        {"name": "ignore-approaching-quota", "filter": "QuotaEligibilityTests",
         "edits": [("Sources/AdaptiveModelRouting/RoutingResult.swift",
                    "&& !(conserveQuota && policy == .automatic && cloudQuota == .approachingLimit)", "&& true")]},
        {"name": "ignore-exhausted-quota", "filter": "QuotaEligibilityTests",
         "edits": [("Sources/AdaptiveModelRouting/RoutingResult.swift",
                    "cloud: cloud && policy != .localOnly && cloudQuota != .exhausted", "cloud: cloud && policy != .localOnly")]},
        {"name": "bypass-cloud-cooldown", "filter": "QuotaScheduleTests|QuotaPersistenceTests",
         "edits": [(coordinator, "now.timeIntervalSince(lastCloudUse) < cloudInterval", "false")]},
        {"name": "forget-persisted-cloud-use", "filter": "QuotaPersistenceTests.testFailedCloudUseIsPersistedBeforeGenerationAndSurvivesIdentityReset",
         "edits": [(core, "lastCloudUse: calibration.lastCloudUse, cloudRetryAfter:", "lastCloudUse: nil, cloudRetryAfter:")]},
        {"name": "ignore-persisted-cloud-use", "filter": "QuotaPersistenceTests.testFailedCloudUseIsPersistedBeforeGenerationAndSurvivesIdentityReset",
         "edits": [(core, "cache.lastCloudUse ?? cache.profile", "cache.profile")]},
        {"name": "bypass-final-quota-check", "filter": "PCCQuotaTests.testQuotaChangesImmediatelyBeforeGenerationAreRechecked",
         "edits": [(core, "guard cloudPermission(false) else { return nil }", "guard true else { return nil }")]},
        {"name": "bypass-secondary-quota-check", "filter": "PCCQuotaTests.testQuotaRecheckBlocksALateOptionalPCCProbe",
         "edits": [(core, "if route == .cloud && !cloudPermission(true) { return nil }", "if false { return nil }")]},
        {"name": "ignore-measurement-age", "filter": "RoutingAccuracyTests.testOnePCCProbeCanDetectAChangedLatencyRegime",
         "edits": [(profile, "exp2(-Double(index) - max(0, latest.timeIntervalSince(sample.date)) / configuration.predictionHalfLife)", "exp2(-Double(index))")]},
        {"name": "break-equal-timestamp-selection", "filter": "RoutingAccuracyTests.testBoundedSelectorMatchesStableSortWithShuffledDatesAndTies",
         "edits": [(profile, "|| ($0.sample.date == sample.date && $0.index > index)", "|| false")]},
        {"name": "repeat-failed-single-provider-refresh", "filter": "QuotaPersistenceTests.testSingleProviderRefreshTimeoutCannotSpendOnEveryRequest",
         "edits": [(profile, "now.timeIntervalSince(max(cloud.latest, lastCloudUse ?? cloud.latest))", "now.timeIntervalSince(cloud.latest)")]},
        {"name": "cancel-promoted-foreground-recovery", "filter": "QuotaEligibilityTests.testAnotherRequestCannotCancelCloudAlreadyUsedForForegroundRecovery",
         "edits": [(coordinator, "cancelJob = { if !probe.isForeground { probe.cancel() } }", "cancelJob = { probe.cancel() }")]},
    ]


def source_digest() -> str:
    """Fingerprint the real source/test inputs without writing to the working checkout."""
    digest = hashlib.sha256()
    for directory in ["Sources", "Tests", "Examples", "AppleExamples"]:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            if ".build" in path.parts:
                continue
            digest.update(str(path.relative_to(ROOT)).encode())
            digest.update(path.read_bytes())
    digest.update((ROOT / "Package.swift").read_bytes())
    return digest.hexdigest()


def detected_fault(code: int, output: str, test_filter: str) -> bool:
    """Count a completed XCTest failure only when it belongs to a test selected for this mutation."""
    if code != 1 or not re.search(r"Executed \d+ tests?, with [1-9]\d* failures?", output):
        return False
    failures = re.findall(r"^Test Case '-\[([\w.]+) (\w+)\]' failed ", output, re.MULTILINE)
    return any(re.search(test_filter, f"{suite}/{method}") for suite, method in failures)


def run(name: str, test_filter: str, workspace: Path, artifacts: Path, timeout: int) -> dict:
    """Save complete logs, kill only the owned process group on timeout, and distinguish test kills from compile errors."""
    command = ["swift", "test", "--package-path", str(workspace), "--scratch-path", str(artifacts / "build"),
               "--cache-path", str(artifacts / "spm-cache"), "--disable-sandbox", "--filter", test_filter]
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(artifacts / "clang-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(artifacts / "swift-cache")
    log = artifacts / f"{name}.log"
    started = time.monotonic()
    with log.open("w") as output:
        process = subprocess.Popen(command, cwd=workspace, stdout=output, stderr=subprocess.STDOUT,
                                   env=environment, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = 124
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
            raise
    text = log.read_text(errors="replace")
    killed = detected_fault(code, text, test_filter)
    result = {"name": name, "exitCode": code, "testKilled": killed,
              "seconds": round(time.monotonic() - started, 2), "filter": test_filter, "log": log.name}
    print(f"{name}: {'TEST DETECTED FAULT' if killed else 'passed' if code == 0 else 'BUILD/TIMEOUT ERROR'} ({result['seconds']}s)", flush=True)
    return result


def main() -> None:
    """Run a clean baseline, each isolated mutation, and a restored baseline without editing the real project."""
    parser = argparse.ArgumentParser(description=__doc__)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    parser.add_argument("--artifacts", type=Path, default=ROOT / ".build" / f"cost-mutations-{stamp}")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    artifacts = args.artifacts.resolve()
    workspace = artifacts / "workspace"
    if workspace.exists():
        raise SystemExit("Choose a fresh artifact directory; existing evidence is preserved.")
    artifacts.mkdir(parents=True, exist_ok=True)
    workspace.mkdir()
    before = source_digest()
    for directory in ["Sources", "Tests", "Examples", "AppleExamples"]:
        shutil.copytree(ROOT / directory, workspace / directory,
                        ignore=shutil.ignore_patterns(".build", ".git", "__pycache__"))
    shutil.copy2(ROOT / "Package.swift", workspace / "Package.swift")
    selected = "CostSafety|CostOwnedStream|FoundationModelsRouterTests|PairedCalibrationTests|PairedStreamingTests|PresetsAndDiagnosticsTests|ProfileControlTests|Quota|RoutingAccuracyTests|RequestControlTests"
    results = []
    baseline = run("baseline", selected, workspace, artifacts, args.timeout)
    results.append(baseline)
    if baseline["exitCode"]:
        (artifacts / "summary.json").write_text(json.dumps({"results": results}, indent=2) + "\n")
        raise SystemExit("Baseline failed; no mutations were executed. Inspect baseline.log.")
    for mutation in mutations():
        originals = {}
        try:
            for relative, old, new in mutation["edits"]:
                path = workspace / relative
                originals.setdefault(path, path.read_bytes())
                text = path.read_text()
                if text.count(old) != 1:
                    raise RuntimeError(f"Mutation anchor must match once: {mutation['name']} / {relative}")
                path.write_text(text.replace(old, new, 1))
            results.append(run(mutation["name"], mutation["filter"], workspace, artifacts, args.timeout))
        finally:
            for path, original in originals.items():
                path.write_bytes(original)
                if path.read_bytes() != original:
                    raise RuntimeError(f"Failed to restore isolated fixture {path}")
            if source_digest() != before:
                raise RuntimeError("Real source/test inputs changed during the campaign; stop and audit before continuing.")
        (artifacts / "summary.json").write_text(json.dumps({"results": results, "realSourceUnchanged": True}, indent=2) + "\n")
    restored = run("restored-baseline", selected, workspace, artifacts, args.timeout)
    results.append(restored)
    detected = sum(r["testKilled"] for r in results[1:-1])
    summary = {"mutations": len(mutations()), "detected": detected, "realSourceUnchanged": source_digest() == before,
               "sourceSHA256": before, "results": results}
    (artifacts / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Detected {detected}/{len(mutations())} deliberate faults; restored baseline exit={restored['exitCode']}. Evidence: {artifacts}")
    if detected != len(mutations()) or restored["exitCode"] or not summary["realSourceUnchanged"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
