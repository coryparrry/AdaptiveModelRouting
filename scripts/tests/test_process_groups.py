"""Regression coverage for timeout cleanup of compilers and test subprocesses."""

import os
import select
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import process_groups, test_cost_mutations


class ProcessGroupTests(unittest.TestCase):
    """Check real process-tree termination and the campaign's timeout call path."""

    def test_terminated_leader_does_not_leave_resistant_child_running(self):
        """Wait for the descendant to ignore TERM, then prove it closed its inherited pipe after cleanup."""
        child = 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print("ready",flush=True); time.sleep(60)'
        leader = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",sys.argv[1]]); time.sleep(60)'
        with subprocess.Popen([sys.executable, '-c', leader, child], stdout=subprocess.PIPE,
                              start_new_session=True) as process:
            try:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'Child failed to start')
                self.assertEqual(process.stdout.readline(), b'ready\n')
                process_groups.stop_process(process, grace_seconds=0.1)
                self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'Child survived group cleanup')
                self.assertEqual(process.stdout.read(), b'')
            except BaseException:
                # Successful EOF verification already proves the fixture exited.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                raise

    def test_mutation_runner_uses_group_cleanup_on_timeout_and_interruption(self):
        """Both exits release the group and preserve the correct failure type before another mutation runs."""
        for failure in (subprocess.TimeoutExpired(['swift'], 1), KeyboardInterrupt()):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as folder, \
                    patch.object(test_cost_mutations.subprocess, 'Popen') as spawn, \
                    patch.object(test_cost_mutations, 'stop_process') as stop:
                spawn.return_value.wait.side_effect = failure
                args = ('fixture', 'Selected', Path(folder), Path(folder), 1)
                if isinstance(failure, subprocess.TimeoutExpired):
                    self.assertEqual(test_cost_mutations.run(*args)['exitCode'], 124)
                else:
                    with self.assertRaises(KeyboardInterrupt):
                        test_cost_mutations.run(*args)
                stop.assert_called_once_with(spawn.return_value)
