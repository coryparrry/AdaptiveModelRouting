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
