"""Exercise the demo launcher's argument and provenance gates without touching the desktop."""

import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import build_demo_app as launcher


class LauncherTests(unittest.TestCase):
    """Keep build, verification and GUI side effects independent."""

    def setUp(self):
        """Create an isolated package, executable and matching provenance for each case."""
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        base = self.root / 'artifacts'
        app = base / 'RoutingDemo.app'
        binary = app / 'Contents/MacOS/RoutingDemo'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'fixture executable')
        for name in ('Package.swift', 'Demo/Package.swift', 'script/build_and_run.sh',
                     'scripts/build_demo_app.py', 'Sources/Lib.swift', 'Demo/Sources/App.swift'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture')
        constants = patch.multiple(launcher, ROOT=self.root, BASE=base, APP=app, BINARY=binary)
        constants.start()
        self.addCleanup(constants.stop)
        signing_environment = patch.dict(os.environ, {'ROUTING_DEMO_SIGNING_ASSETS': ''})
        signing_environment.start()
        self.addCleanup(signing_environment.stop)
        (base / 'provenance.json').write_text(json.dumps({
            'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'sourceFiles': launcher.source_hashes(),
        }))

    def stage_fixture(self):
        """Stage a synthetic compiled binary while requiring build-only to leave process ownership untouched."""
        compiled = self.root / '.build/demo-gui-build/debug/RoutingDemo'
        compiled.parent.mkdir(parents=True, exist_ok=True)
        compiled.write_bytes(b'new executable')
        with patch.object(sys, 'argv', ['launcher', '--build-only']), patch.object(launcher, 'running_pid') as pid, \
                patch.object(launcher, 'run_logged') as logged, patch.object(launcher.subprocess, 'run') as launch, \
                contextlib.redirect_stdout(io.StringIO()):
            launcher.main()
            self.assertEqual([call.args[0] for call in logged.call_args_list], ['build', 'sign', 'verify'])
            pid.assert_not_called()
            launch.assert_not_called()

    def test_build_only_stages_separate_signed_candidate(self):
        """A completed build leaves the previous live bundle, provenance and launch record intact."""
        launch_record = launcher.BASE / 'last-launch.json'
        launch_record.write_text('{"pid": 123}')
        prior_manifest = (launcher.BASE / 'provenance.json').read_bytes()
        self.stage_fixture()
        self.assertEqual(launch_record.read_text(), '{"pid": 123}')
        self.assertEqual(launcher.BINARY.read_bytes(), b'fixture executable')
        self.assertEqual((launcher.BASE / 'provenance.json').read_bytes(), prior_manifest)
        staged = launcher.BASE / 'staged' / launcher.APP.name
        self.assertEqual((staged / 'Contents/MacOS/RoutingDemo').read_bytes(), b'new executable')
        with patch.object(sys, 'argv', ['launcher', '--verify']), patch.object(launcher, 'run_logged') as logged:
            launcher.main()
            self.assertEqual(logged.call_args.args[1][-1], str(staged))

    def test_failed_build_or_sign_preserves_live_and_prior_candidate(self):
        """Both the active session and its verified replacement survive failures before promotion."""
        self.stage_fixture()
        prior = launcher.BASE / 'staged'
        snapshot = (prior / 'provenance.json').read_bytes()
        for mode in ('run', '--build-only'):
            for stage in ('build', 'sign', 'verify'):
                with self.subTest(mode=mode, stage=stage):
                    def fail_step(name, command, environment):
                        """Fail at the selected prerequisite."""
                        if name == stage:
                            raise subprocess.CalledProcessError(1, command)
                    with patch.object(sys, 'argv', ['launcher', mode]), patch.object(launcher, 'stop_running_demo') as stop, \
                            patch.object(launcher, 'run_logged', side_effect=fail_step), patch.object(launcher.subprocess, 'run') as launch:
                        with self.assertRaises(subprocess.CalledProcessError):
                            launcher.main()
                        stop.assert_not_called()
                        launch.assert_not_called()
                    self.assertEqual(launcher.BINARY.read_bytes(), b'fixture executable')
                    self.assertEqual((prior / 'provenance.json').read_bytes(), snapshot)

    def test_launch_only_promotes_verified_build(self):
        """Launch uses the newly staged binary after verifying the copy and stopping the owned previous app."""
        self.stage_fixture()
        events = []

        def verify(name, command, environment):
            """Record the hash-checked signatures preceding the ownership handoff."""
            events.append(name)
            self.assertEqual((Path(command[-1]) / 'Contents/MacOS/RoutingDemo').read_bytes(), b'new executable')

        def stop():
            """Require the old executable to remain in place until the stop."""
            events.append('stop')
            self.assertEqual(launcher.BINARY.read_bytes(), b'fixture executable')

        def open_demo(command, check):
            """Confirm Launch Services receives the promoted live bundle."""
            events.append('open')
            self.assertEqual(command, ['/usr/bin/open', '-n', str(launcher.APP)])
            self.assertEqual(launcher.BINARY.read_bytes(), b'new executable')

        with patch.object(sys, 'argv', ['launcher', '--launch-only']), patch.object(launcher, 'run_logged', side_effect=verify), \
                patch.object(launcher, 'stop_running_demo', side_effect=stop), patch.object(launcher, 'running_pid', return_value=456), \
                patch.object(launcher.subprocess, 'run', side_effect=open_demo), contextlib.redirect_stdout(io.StringIO()):
            launcher.main()
        self.assertEqual(events, ['verify-launch', 'verify-launch', 'stop', 'open'])
        self.assertEqual(json.loads((launcher.BASE / 'last-launch.json').read_text())['pid'], 456)
        self.assertEqual((launcher.BASE / 'provenance.json').read_bytes(), (launcher.BASE / 'staged/provenance.json').read_bytes())

    def test_manifest_install_failure_restores_live_bundle(self):
        """An interrupted promotion leaves the previous binary and manifest together for retry."""
        self.stage_fixture()
        previous = (launcher.BASE / 'provenance.json').read_bytes()
        with patch.object(sys, 'argv', ['launcher', '--launch-only']), patch.object(launcher, 'run_logged'), \
                patch.object(launcher, 'stop_running_demo'), patch.object(Path, 'replace', side_effect=PermissionError), \
                patch.object(launcher.subprocess, 'run') as launch:
            with self.assertRaises(PermissionError):
                launcher.main()
            launch.assert_not_called()
        self.assertEqual(launcher.BINARY.read_bytes(), b'fixture executable')
        self.assertEqual((launcher.BASE / 'provenance.json').read_bytes(), previous)
        staged_binary = launcher.BASE / 'staged' / launcher.BINARY.relative_to(launcher.BASE)
        self.assertEqual(staged_binary.read_bytes(), b'new executable')

    def check_failed_launch_and_retry(self, previous_binary, previous_manifest):
        """Exercise an open error and a missing process before retrying the same staged build."""
        manifest = launcher.BASE / 'provenance.json'
        record = launcher.BASE / 'last-launch.json'
        for failure in ('open', 'timeout'):
            with self.subTest(failure=failure):
                record.write_text('{"pid": 123}')
                open_error = subprocess.CalledProcessError(1, ['open']) if failure == 'open' else None
                with patch.object(launcher, 'stop_running_demo'), patch.object(launcher, 'run_logged'), \
                        patch.object(launcher.subprocess, 'run', side_effect=open_error), \
                        patch.object(launcher, 'running_pid', return_value=None), \
                        patch.object(launcher.time, 'monotonic', side_effect=[0, 11]):
                    with self.assertRaises(subprocess.CalledProcessError if open_error else RuntimeError):
                        launcher.prepare_and_launch('--launch-only', {})
                if previous_binary is None:
                    self.assertFalse(launcher.APP.exists())
                    self.assertFalse(manifest.exists())
                else:
                    self.assertEqual(launcher.BINARY.read_bytes(), previous_binary)
                    self.assertEqual(manifest.read_bytes(), previous_manifest)
                self.assertFalse(record.exists(), 'A stopped process must have no ownership record')

        with patch.object(launcher, 'stop_running_demo'), patch.object(launcher, 'run_logged'), \
                patch.object(launcher.subprocess, 'run'), patch.object(launcher, 'running_pid', return_value=456), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(launcher.prepare_and_launch('--launch-only', {}), 456)
        self.assertEqual(launcher.BINARY.read_bytes(), b'new executable')
        self.assertEqual(manifest.read_bytes(), (launcher.BASE / 'staged/provenance.json').read_bytes())
        self.assertEqual(json.loads(record.read_text())['pid'], 456)

    def test_failed_replacement_restores_installed_build_until_retry(self):
        """Launch errors restore both artifacts from the working installation."""
        self.stage_fixture()
        self.check_failed_launch_and_retry(launcher.BINARY.read_bytes(), (launcher.BASE / 'provenance.json').read_bytes())

    def test_failed_first_install_leaves_only_staged_build_for_retry(self):
        """A first launch without a working predecessor keeps the verified stage available for retry."""
        self.stage_fixture()
        shutil.rmtree(launcher.APP)
        (launcher.BASE / 'provenance.json').unlink()
        self.check_failed_launch_and_retry(None, None)

    def test_failed_legacy_launch_preserves_only_bundle(self):
        """An older single-bundle layout has no staged replacement to undo."""
        manifest = launcher.BASE / 'provenance.json'
        previous_manifest = manifest.read_bytes()
        record = launcher.BASE / 'last-launch.json'
        record.write_text('{"pid": 123}')
        with patch.object(launcher, 'stop_running_demo'), patch.object(launcher, 'run_logged'), \
                patch.object(launcher.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['open'])):
            with self.assertRaises(subprocess.CalledProcessError):
                launcher.prepare_and_launch('--launch-only', {})
        self.assertEqual(launcher.BINARY.read_bytes(), b'fixture executable')
        self.assertEqual(manifest.read_bytes(), previous_manifest)
        self.assertFalse(record.exists())

    def test_failed_launch_record_stops_confirmed_process_and_restores_install(self):
        """A running replacement must be stopped before rolling back an unrecorded launch."""
        self.stage_fixture()
        manifest = launcher.BASE / 'provenance.json'
        previous_manifest = manifest.read_bytes()
        record = launcher.BASE / 'last-launch.json'
        for method in ('write_text', 'replace'):
            with self.subTest(method=method):
                original = getattr(Path, method)

                def fail_record(path, *args, **kwargs):
                    """Fail only the ownership write or rename after the candidate is running."""
                    if path.name == record.name:
                        raise PermissionError('test launch record failure')
                    return original(path, *args, **kwargs)

                def stop_candidate(pid, signum):
                    """Require the matching candidate to be installed when the signal is sent."""
                    self.assertEqual(launcher.BINARY.read_bytes(), b'new executable')
                    self.assertEqual((pid, signum), (456, launcher.signal.SIGTERM))

                with patch.object(Path, method, fail_record), patch.object(launcher, 'run_logged'), \
                        patch.object(launcher.subprocess, 'run'), patch.object(launcher, 'running_pid', \
                            side_effect=[None, 456, 456, None, None]), \
                        patch.object(launcher.os, 'kill', side_effect=stop_candidate) as kill:
                    with self.assertRaisesRegex(PermissionError, 'test launch record failure'):
                        launcher.prepare_and_launch('--launch-only', {})
                    kill.assert_called_once()
                self.assertEqual(launcher.BINARY.read_bytes(), b'fixture executable')
                self.assertEqual(manifest.read_bytes(), previous_manifest)
                self.assertFalse(record.exists())

        with patch.object(launcher, 'run_logged'), patch.object(launcher.subprocess, 'run'), \
                patch.object(launcher, 'running_pid', side_effect=[None, 789]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(launcher.prepare_and_launch('--launch-only', {}), 789)
        self.assertEqual(json.loads(record.read_text())['pid'], 789)

    def test_launch_only_requires_exact_input_set(self):
        """Adding, removing or editing a source rejects launch before disturbing the current app."""
        cases = [('Sources/New.swift', 'new'), ('Demo/Sources/App.swift', None), ('Sources/Lib.swift', 'edit')]
        for name, change in cases:
            with self.subTest(name=name), patch.object(sys, 'argv', ['launcher', '--launch-only']), \
                    patch.object(launcher, 'running_pid') as pid, patch.object(launcher, 'run_logged') as run, \
                    patch.object(launcher.subprocess, 'run') as launch:
                source = self.root / name
                if change is None:
                    source.unlink()
                else:
                    source.write_text(change)
                with self.assertRaisesRegex(RuntimeError, 'Source files changed'):
                    launcher.main()
                pid.assert_not_called()
                launch.assert_not_called()
                run.assert_not_called()
                if change == 'new':
                    source.unlink()
                else:
                    source.write_text('fixture')

    def test_build_rejects_changing_inputs(self):
        """A source added during compilation must not be recorded as part of the completed binary."""
        def add_source(name, command, env):
            """Simulate a source added while swift build is still running."""
            self.assertEqual(name, 'build')
            (self.root / 'Sources/New.swift').write_text('late input')
        with patch.object(sys, 'argv', ['launcher', '--build-only']), patch.object(launcher, 'running_pid', return_value=None), \
                patch.object(launcher, 'run_logged', side_effect=add_source), patch.object(launcher.subprocess, 'run') as launch:
            with self.assertRaisesRegex(RuntimeError, 'during build'):
                launcher.main()
            launch.assert_not_called()

    def test_verify_checks_only_staged_signature_and_inputs(self):
        """Verification never stops, rebuilds or launches the demo."""
        with patch.object(sys, 'argv', ['launcher', '--verify']), patch.object(launcher, 'running_pid') as pid, \
                patch.object(launcher, 'run_logged') as logged, patch.object(launcher.subprocess, 'run') as launch:
            launcher.main()
            self.assertEqual(logged.call_count, 1)
            self.assertEqual(logged.call_args.args[1][:3], ['codesign', '--verify', '--strict'])
            pid.assert_not_called()
            launch.assert_not_called()

    def test_invalid_combinations_have_no_side_effects(self):
        """Trailing arguments and conflicting modes are rejected before the app is touched."""
        for args in (['--build-only', 'extra'], ['--verify', '--logs'], ['run', '--launch-only'],
                     ['--launch-only', '--launch-only'], ['--ver']):
            with self.subTest(args=args), patch.object(sys, 'argv', ['launcher', *args]), \
                    contextlib.redirect_stderr(io.StringIO()), patch.object(launcher, 'running_pid') as pid, \
                    patch.object(launcher.subprocess, 'run') as launch:
                with self.assertRaises(SystemExit) as failure:
                    launcher.main()
                self.assertEqual(failure.exception.code, 2)
                pid.assert_not_called()
                launch.assert_not_called()
