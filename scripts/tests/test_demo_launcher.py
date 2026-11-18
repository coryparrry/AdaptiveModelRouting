"""Exercise the demo launcher's argument and provenance gates without touching the desktop."""

import contextlib
import hashlib
import io
import json
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
        (base / 'provenance.json').write_text(json.dumps({
            'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'sourceFiles': launcher.source_hashes(),
        }))

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
