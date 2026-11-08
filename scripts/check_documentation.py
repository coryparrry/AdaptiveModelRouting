#!/usr/bin/env python3
"""Enforce documentation coverage for authored Swift declarations and Python callables."""

import ast
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT_DECLARATION = re.compile(
    r"\s*(?:(?:public|private|internal|fileprivate|final|static|nonisolated|mutating|isolated|override|convenience|required)\s+)*"
    r"(?:func|init|deinit|class|struct|enum|protocol|actor)\b"
)


def swift_coverage(path: Path) -> tuple[int, int]:
    """Count authored declarations with an adjacent Swift documentation comment, ignoring attributes."""
    lines = path.read_text().splitlines()
    total = documented = 0
    for index, line in enumerate(lines):
        if not SWIFT_DECLARATION.match(line):
            continue
        total += 1
        previous = index - 1
        while previous >= 0 and lines[previous].strip().startswith("@"):
            previous -= 1
        has_documentation = previous >= 0 and lines[previous].lstrip().startswith("///")
        if previous >= 0 and lines[previous].rstrip().endswith("*/"):
            while previous >= 0 and "/*" not in lines[previous]:
                previous -= 1
            has_documentation = previous >= 0 and lines[previous].lstrip().startswith("/**")
        documented += has_documentation
        if not has_documentation:
            print(f"Undocumented: {path.relative_to(ROOT)}:{index + 1}")
    return total, documented


def python_coverage(path: Path) -> tuple[int, int]:
    """Use Python's AST to check functions, methods and classes without executing repository code."""
    total = documented = 0
    for node in ast.walk(ast.parse(path.read_text(), filename=str(path))):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            total += 1
            has_documentation = bool(ast.get_docstring(node))
            documented += has_documentation
            if not has_documentation:
                print(f"Undocumented: {path.relative_to(ROOT)}:{node.lineno}")
    return total, documented


def source_files(suffix: str):
    """Prune generated/build trees before walking instead of traversing their cached sources."""
    for directory in ["Sources", "Examples", "AppleExamples", "Tests", "Demo", "scripts"]:
        for folder, directories, filenames in os.walk(ROOT / directory):
            directories[:] = [name for name in directories if name not in {".build", ".swiftpm", "__pycache__"}]
            for filename in filenames:
                if filename.endswith(suffix):
                    yield Path(folder) / filename


def main() -> None:
    """Apply the 85% minimum separately per language so a larger language cannot mask another's shortfall."""
    for suffix, checker in [(".swift", swift_coverage), (".py", python_coverage)]:
        total = documented = 0
        for path in source_files(suffix):
            count, covered = checker(path)
            total += count
            documented += covered
        fraction = documented / total if total else 1
        print(f"{suffix}: {documented}/{total} declarations documented ({fraction:.1%})")
        if fraction < 0.85:
            raise SystemExit(f"Documentation coverage below 85% for {suffix}.")
    print("Swift coverage is lexical; Python coverage uses AST docstrings.")


if __name__ == "__main__":
    main()
