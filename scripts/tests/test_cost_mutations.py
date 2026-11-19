"""Fast checks for the cost fault-injection campaign without running Swift builds."""

import re
import unittest

from scripts import test_cost_mutations as campaign


class MutationTests(unittest.TestCase):
    """Check the mutation catalog against the checkout and validate XCTest failure attribution."""

    def test_catalog_matches_current_sources_and_xctests(self):
        """Each edit applies once and each filter alternative matches at least one authored XCTest."""
        test_names = []
        for path in (campaign.ROOT / "Tests/AdaptiveModelRoutingTests").glob("*.swift"):
            suite = None
            for line in path.read_text().splitlines():
                declaration = re.match(r"(?:final )?class (\w+): XCTestCase\b", line)
                if declaration:
                    suite = declaration[1]
                method = re.match(r"    func (test\w+)\(", line)
                if suite and method:
                    test_names.append(f"AdaptiveModelRoutingTests.{suite}/{method[1]}")
        for mutation in campaign.mutations():
            with self.subTest(mutation=mutation["name"]):
                edited = {}
                for relative, old, new in mutation["edits"]:
                    source = edited.get(relative, (campaign.ROOT / relative).read_text())
                    self.assertEqual(source.count(old), 1, relative)
                    self.assertNotEqual(old, new)
                    edited[relative] = source.replace(old, new, 1)
                for selector in mutation["filter"].split("|"):
                    self.assertTrue(any(re.search(selector, name) for name in test_names), selector)

    def test_only_attributed_completed_test_failures_count(self):
        """Compilation errors, timeouts and failures outside the target cannot kill a mutation."""
        summary = "Executed 1 test, with 1 failure (0 unexpected)"
        failure = "Test Case '-[AdaptiveModelRoutingTests.ExampleTests testExample]' failed (0.01 seconds)."
        log = f"{failure}\n{summary}"
        selector = "ExampleTests.testExample"
        self.assertTrue(campaign.detected_fault(1, log, selector))
        self.assertFalse(campaign.detected_fault(1, log, "OtherTests"))
        self.assertFalse(campaign.detected_fault(124, log, selector))
        self.assertFalse(campaign.detected_fault(0, log, selector))
        self.assertFalse(campaign.detected_fault(1, "error: missing symbol", selector))
        self.assertFalse(campaign.detected_fault(1, summary, selector))
