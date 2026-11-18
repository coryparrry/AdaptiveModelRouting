"""Regression tests for coverage detection and attributable, bounded validation results."""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import check_documentation, validate


class DocumentationTests(unittest.TestCase):
    """Recognize valid documentation and reject uncovered code without traversing build artifacts."""

    def test_swift_attributes_and_block_comments(self):
        """Attribute lines and both Swift doc-comment styles count while an undocumented function does not."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "Example.swift"
            source.write_text("""/// A documented type.
@MainActor
final class Example {
    /// A documented method.
    func documented() {}
    /** A documented initializer. */
    init() {}
    func missing() {}
}
""")
            with patch.object(check_documentation, "ROOT", root), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(check_documentation.swift_coverage(source), (4, 3))

    def test_python_ast_and_build_exclusion(self):
        """Python methods are checked with AST and ignored trees do not contribute declarations."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "scripts").mkdir()
            source = root / "scripts" / "fixture.py"
            source.write_text('''class Example:
    """A documented class."""
    def method(self):
        """A documented method."""
    async def missing(self):
        pass
''')
            (root / "Demo" / ".build").mkdir(parents=True)
            (root / "Demo" / ".build" / "generated.py").write_text("def generated(): pass")
            with patch.object(check_documentation, "ROOT", root), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(check_documentation.python_coverage(source), (3, 2))
                self.assertEqual(list(check_documentation.source_files(".py")), [source])
                with self.assertRaises(SystemExit):
                    check_documentation.main()


class RunnerTests(unittest.TestCase):
    """Check command outcomes, evidence and timeout behavior using harmless child processes."""

    def test_success_and_failure_evidence(self):
        """A failed command preserves its exact exit code and full log alongside earlier successes."""
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            root = Path(folder)
            results = []
            validate.run_step("success", [sys.executable, "-c", "print('passed')"], root, os.environ.copy(), results)
            with self.assertRaises(SystemExit) as failure:
                validate.run_step("failure", [sys.executable, "-c", "print('specific failure'); raise SystemExit(3)"],
                                  root, os.environ.copy(), results)
            self.assertEqual(failure.exception.code, 3)
            self.assertIn("specific failure", (root / "failure.log").read_text())
            summary = json.loads((root / "summary.json").read_text())
            self.assertEqual([step["exitCode"] for step in summary], [0, 3])

    def test_failed_preflight_replaces_existing_passing_summary(self):
        """A later run's SDK failure replaces previous success and is visible before any stage runs."""
        with tempfile.TemporaryDirectory() as folder, patch.object(sys, "argv", ["validate", "--artifacts", folder]):
            summary = Path(folder) / "summary.json"
            summary.write_text(json.dumps([{"step": "old run", "exitCode": 0}]))

            def old_sdk(*args, **kwargs):
                """Check that machine readers can identify the new active run even during SDK lookup."""
                self.assertEqual(json.loads(summary.read_text())[-1]["status"], "running")
                return "26.0"

            with patch.object(validate.subprocess, "check_output", side_effect=old_sdk):
                with self.assertRaises(SystemExit):
                    validate.main()
            rows = json.loads(summary.read_text())
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["status"], "failed")
            self.assertEqual(rows[0]["exitCode"], 1)
            self.assertIn("Xcode 27", rows[0]["detail"])

    def test_interrupt_after_passed_stage_is_marked_incomplete(self):
        """An interrupted validation retains its completed stages together with the terminal status."""
        with tempfile.TemporaryDirectory() as folder, patch.object(sys, "argv", ["validate", "--artifacts", folder]):
            def interrupt(args, artifacts, results):
                """Pass a real harmless stage and interrupt before the next one."""
                validate.run_step("early", [sys.executable, "-c", "pass"], artifacts, os.environ.copy(), results)
                self.assertEqual(json.loads((artifacts / "summary.json").read_text())[-1]["status"], "running")
                raise KeyboardInterrupt()

            with patch.object(validate, "validate", side_effect=interrupt), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(KeyboardInterrupt):
                    validate.main()
            early, final = json.loads((Path(folder) / "summary.json").read_text())
            self.assertEqual(early["exitCode"], 0)
            self.assertEqual(final["status"], "interrupted")
            self.assertEqual(final["exitCode"], 130)

    def test_early_failure_survives_long_success_tail(self):
        """Hosted logs retain attributed failures even when later passing tests push them out of the tail."""
        lines = ["Example.swift:42: error: missing asynchronous signal"] + [f"passed case {i}" for i in range(100)]
        excerpt = validate.failure_excerpt(lines)
        self.assertIn(lines[0], excerpt)
        self.assertIn(lines[-1], excerpt)
        self.assertLessEqual(len(excerpt.splitlines()), 55)
        many_errors = validate.failure_excerpt([f"error: case {i}" for i in range(100)])
        self.assertEqual(len(many_errors.splitlines()), 55)

    def test_timeout_is_bounded(self):
        """A stalled validation step is terminated and attributed as timeout rather than hanging the pipeline."""
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            root = Path(folder)
            results = []
            with self.assertRaises(SystemExit) as failure:
                validate.run_step("timeout", [sys.executable, "-c", "import time; time.sleep(30)"],
                                  root, os.environ.copy(), results, timeout=0.05)
            self.assertEqual(failure.exception.code, 124)
            self.assertEqual(results[0]["exitCode"], 124)
            self.assertIn("exceeded", (root / "timeout.log").read_text())


if __name__ == "__main__":
    unittest.main()
