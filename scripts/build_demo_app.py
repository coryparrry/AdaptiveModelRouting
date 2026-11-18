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


def main():
    """Build or reopen the actual demo without auto-running prompts or changing model defaults."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', nargs='?', default='run', choices=['run', '--build-only', '--launch-only', '--verify', '--logs', '--telemetry'])
    # Accept flag-like modes without treating them as argparse option names.
    import sys
    mode = sys.argv[1] if len(sys.argv) == 2 else 'run'
    if mode not in ['run', '--build-only', '--launch-only', '--verify', '--logs', '--telemetry']:
        parser.error('Unsupported mode')
    BASE.mkdir(parents=True, exist_ok=True)
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
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(ROOT / '.build/startup-clang-cache'),
        SWIFTPM_MODULECACHE_OVERRIDE=str(ROOT / '.build/startup-swift-cache'))
    if mode != '--launch-only':
        command = ['swift', 'build', '--package-path', str(ROOT / 'Demo'), '--scratch-path', str(ROOT / '.build/demo-gui-build'),
            '--cache-path', str(ROOT / '.build/startup-spm-cache'), '--disable-sandbox', '-j', '2', '--product', 'RoutingDemo']
        run_logged('build', command, environment)
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
        source_files = sorted((ROOT / 'Sources').rglob('*.swift')) + sorted((ROOT / 'Demo/Sources').rglob('*.swift')) + [Path(__file__).resolve(), ROOT / 'script/build_and_run.sh', ROOT / 'Demo/Package.swift', ROOT / 'Package.swift']
        manifest = {'binarySHA256': hashlib.sha256(BINARY.read_bytes()).hexdigest(), 'bundleIdentifier': info['CFBundleIdentifier'],
            'managedPCCSigning': bool(assets), 'sourceFiles': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}}
        (BASE / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(json.dumps({'built': True, **{k: v for k, v in manifest.items() if k != 'sourceFiles'}}), flush=True)
    if mode == '--build-only':
        return
    manifest = json.loads((BASE / 'provenance.json').read_text())
    if hashlib.sha256(BINARY.read_bytes()).hexdigest() != manifest['binarySHA256']:
        raise RuntimeError('Staged executable differs from its build provenance')
    for name, expected in manifest['sourceFiles'].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Source changed since build: {name}')
    run_logged('verify-launch', ['codesign', '--verify', '--strict', str(APP)], environment)
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
