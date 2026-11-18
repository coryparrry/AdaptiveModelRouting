#!/usr/bin/env python3
"""Stage the SwiftPM demo as a signed macOS GUI app and launch it through Launch Services."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / '.build/demo-app'
APP = BASE / 'RoutingDemo.app'
BINARY = APP / 'Contents/MacOS/RoutingDemo'


def run_logged(name, command, environment):
    """Save complete build/sign logs and raise on the first failed prerequisite."""
    with (BASE / (name + '.log')).open('w') as output:
        subprocess.run(command, cwd=ROOT, env=environment, stdout=output, stderr=subprocess.STDOUT, check=True)


def running_pid():
    """Match only this checkout's exact staged executable, never another app with the same bundle ID."""
    output = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
    matches = [int(line.strip().split(None, 1)[0]) for line in output.splitlines()
        if len(line.strip().split(None, 1)) == 2 and line.strip().split(None, 1)[1] == str(BINARY)]
    if len(matches) > 1:
        raise RuntimeError('Multiple owned demo processes; close them before relaunch')
    return matches[0] if matches else None


def source_hashes():
    """Capture the complete set of package sources, manifests and launcher inputs for this build."""
    files = [ROOT / name for name in ('Package.swift', 'Demo/Package.swift', 'script/build_and_run.sh',
                                      'scripts/build_demo_app.py')]
    for folder in (ROOT / 'Sources', ROOT / 'Demo/Sources'):
        files.extend(sorted(folder.rglob('*.swift')))
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}


def verify_staged(environment):
    """Check the staged binary, signature and current input set before starting or stopping any app."""
    manifest = json.loads((BASE / 'provenance.json').read_text())
    if hashlib.sha256(BINARY.read_bytes()).hexdigest() != manifest['binarySHA256']:
        raise RuntimeError('Staged executable differs from its build provenance')
    if source_hashes() != manifest['sourceFiles']:
        raise RuntimeError('Source files changed since build; rebuild the demo')
    run_logged('verify-launch', ['codesign', '--verify', '--strict', str(APP)], environment)


def stop_running_demo():
    """Stop the previously recorded process only when it still runs the owned executable."""
    existing = running_pid()
    if existing:
        record = json.loads((BASE / 'last-launch.json').read_text())
        if existing != record['pid']:
            raise RuntimeError('Refusing to stop a demo process not owned by this build script')
        os.kill(existing, signal.SIGTERM)
        deadline = time.monotonic() + 10
        while running_pid() is not None and time.monotonic() < deadline:
            time.sleep(.1)
        if running_pid() is not None:
            raise RuntimeError('Owned demo did not exit; refusing overlapping launches')


def main():
    """Build, verify or launch the demo after validating the entire command line."""
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('command', nargs='?', choices=['run'])
    modes = parser.add_mutually_exclusive_group()
    for mode in ('--build-only', '--launch-only', '--verify', '--logs', '--telemetry'):
        modes.add_argument(mode, dest='mode', action='store_const', const=mode)
    args = parser.parse_args()
    if len(sys.argv[1:]) > 1:
        parser.error('Choose run or one mode option')
    mode = args.mode or 'run'
    BASE.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(ROOT / '.build/startup-clang-cache'),
        SWIFTPM_MODULECACHE_OVERRIDE=str(ROOT / '.build/startup-swift-cache'))
    if mode in ('--verify', '--launch-only'):
        verify_staged(environment)
        if mode == '--verify':
            return
    stop_running_demo()
    if mode != '--launch-only':
        inputs = source_hashes()
        command = ['swift', 'build', '--package-path', str(ROOT / 'Demo'), '--scratch-path', str(ROOT / '.build/demo-gui-build'),
            '--cache-path', str(ROOT / '.build/startup-spm-cache'), '--disable-sandbox', '-j', '2', '--product', 'RoutingDemo']
        run_logged('build', command, environment)
        if source_hashes() != inputs:
            raise RuntimeError('Source files changed during build; rebuild the demo')
        (BINARY.parent).mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / '.build/demo-gui-build/debug/RoutingDemo', BINARY)
        info = {'CFBundleExecutable': 'RoutingDemo', 'CFBundleIdentifier': 'dev.adaptivemodelrouting.demo',
            'CFBundleName': 'Routing Demo', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '0.0.1', 'LSMinimumSystemVersion': '27.0', 'NSPrincipalClass': 'NSApplication'}
        assets = os.environ.get('ROUTING_DEMO_SIGNING_ASSETS')
        if assets:
            assets = Path(assets)
            prior_info = plistlib.loads((assets / 'Info.plist').read_bytes())
            info['CFBundleIdentifier'] = prior_info['CFBundleIdentifier']
            shutil.copy2(assets / 'LiveRouterQualification.app/Contents/embedded.provisionprofile', APP / 'Contents/embedded.provisionprofile')
            signing = ['--sign', os.environ['ROUTING_DEMO_SIGNING_IDENTITY'], '--entitlements', str(assets / 'entitlements.plist')]
        else:
            signing = ['--sign', '-']
            profile = APP / 'Contents/embedded.provisionprofile'
            if profile.exists():
                profile.unlink()
        (APP / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        run_logged('sign', ['codesign', '--force', *signing, str(APP)], environment)
        run_logged('verify', ['codesign', '--verify', '--strict', str(APP)], environment)
        manifest = {'binarySHA256': hashlib.sha256(BINARY.read_bytes()).hexdigest(), 'bundleIdentifier': info['CFBundleIdentifier'],
            'managedPCCSigning': bool(assets), 'sourceFiles': inputs}
        (BASE / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(json.dumps({'built': True, **{k: v for k, v in manifest.items() if k != 'sourceFiles'}}), flush=True)
    if mode == '--build-only':
        return
    subprocess.run(['/usr/bin/open', '-n', str(APP)], check=True)
    deadline = time.monotonic() + 10
    pid = running_pid()
    while pid is None and time.monotonic() < deadline:
        time.sleep(.1)
        pid = running_pid()
    if pid is None:
        raise RuntimeError('Launch Services did not start the staged demo')
    (BASE / 'last-launch.json').write_text(json.dumps({'pid': pid, 'at': time.time(), 'bundle': str(APP)}, indent=2) + '\n')
    print(json.dumps({'launched': True, 'pid': pid, 'bundle': str(APP)}), flush=True)
    if mode in ('--logs', '--telemetry'):
        predicate = f'processID == {pid}' if mode == '--logs' else f'processID == {pid} AND subsystem == "AdaptiveModelRouting"'
        subprocess.run(['/usr/bin/log', 'stream', '--level', 'debug', '--style', 'ndjson', '--predicate', predicate], check=True)


if __name__ == '__main__':
    main()
