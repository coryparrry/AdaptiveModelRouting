"""Exercise release state transitions without writing to GitHub."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from scripts import release

REPO = "coryparrry/AdaptiveModelRouting"
TAG = "v0.2.0"
COMMIT = "a" * 40
OTHER_COMMIT = "b" * 40
DRAFT = {
    "id": 27, "tag_name": TAG, "draft": True, "prerelease": False, "target_commitish": COMMIT,
    "html_url": f"https://github.com/{REPO}/releases/tag/{TAG}",
}
PUBLISHED = dict(DRAFT, draft=False)


class ReleaseTests(unittest.TestCase):
    """Keep draft preparation, private staging, and public deployment distinct."""

    def test_draft_is_found_on_later_page(self):
        """An unpublished draft can be found without a remote tag."""
        with patch.object(release, "api", return_value=[[PUBLISHED | {"tag_name": "v0.1.0"}], [DRAFT]]) as api:
            self.assertEqual(release.find_release(TAG), DRAFT)
        api.assert_called_once_with("/releases?per_page=100", "--paginate", "--slurp")

    def test_tag_only_bootstrap(self):
        """Permit the single historical tag with its verified commit and no GitHub release."""
        with (patch.object(release, "manifest_tag", return_value=release.INITIAL_TAG),
              patch.object(release, "find_release", return_value=None),
              patch.object(release, "tag_commit", return_value=release.INITIAL_COMMIT)):
            self.assertTrue(release.can_propose())

    def test_prevent_new_version_while_pending(self):
        """Both an in-progress draft and a failed draft creation stop new proposals."""
        with patch.object(release, "manifest_tag", return_value=TAG):
            with patch.object(release, "find_release", return_value=DRAFT):
                self.assertFalse(release.can_propose())
            with patch.object(release, "find_release", return_value=None):
                with self.assertRaisesRegex(ValueError, "no stable release"):
                    release.can_propose()

    def test_private_repo_does_not_publish(self):
        """Refuse a publish dispatch before querying or changing releases."""
        with patch.object(release, "api", return_value={"visibility": "private"}) as api:
            with self.assertRaisesRegex(ValueError, "public repository"):
                release.resolve(TAG, COMMIT, publishing=True)
        api.assert_called_once_with("")

    def test_draft_matches_the_version_and_main(self):
        """Accept the exact draft, and reject a different SHA or an existing Git tag."""
        with (patch.object(release, "find_release", return_value=DRAFT),
              patch.object(release, "tag_commit", return_value=None) as ref,
              patch.object(release, "manifest_tag", return_value=TAG),
              patch.object(release, "require_main_commit") as require_main):
            self.assertEqual(release.resolve(TAG, COMMIT), DRAFT)
            require_main.assert_called_once_with(COMMIT)
            with self.assertRaisesRegex(ValueError, "must agree"):
                release.resolve(TAG, OTHER_COMMIT)
            ref.return_value = COMMIT
            with self.assertRaisesRegex(ValueError, "already has a Git tag"):
                release.resolve(TAG, COMMIT)

    def test_candidate_belongs_to_current_main(self):
        """Accept a release commit on main and reject an unrelated or removed commit."""
        comparison = {"status": "ahead", "merge_base_commit": {"sha": COMMIT}}
        with patch.object(release, "api", return_value=comparison) as api:
            release.require_main_commit(COMMIT)
            api.assert_called_once_with(f"/compare/{COMMIT}...main?per_page=1")
            comparison["status"] = "identical"
            release.require_main_commit(COMMIT)
            comparison["merge_base_commit"]["sha"] = OTHER_COMMIT
            with self.assertRaisesRegex(ValueError, "must still be on main"):
                release.require_main_commit(COMMIT)
            comparison.update(status="behind", merge_base_commit={"sha": COMMIT})
            with self.assertRaisesRegex(ValueError, "must still be on main"):
                release.require_main_commit(COMMIT)

    def test_published_retry_requires_same_commit(self):
        """Verify an existing stable publication and reject a moved version tag."""
        with (patch.object(release, "find_release", return_value=PUBLISHED),
              patch.object(release, "tag_commit", return_value=COMMIT)):
            self.assertEqual(release.resolve(TAG, COMMIT), PUBLISHED)
            with self.assertRaisesRegex(ValueError, "does not resolve"):
                release.resolve(TAG, OTHER_COMMIT)

    def test_draft_replaced_after_staging(self):
        """Write nothing if the selected release changed identity."""
        with (patch.object(release, "resolve", return_value=DRAFT),
              patch.object(release, "api") as api):
            with self.assertRaisesRegex(ValueError, "replaced"):
                release.publish(TAG, COMMIT, DRAFT["id"] + 1)
        api.assert_not_called()

    def test_published_retry_writes_nothing(self):
        """An already-published matching ID needs no release update."""
        with (patch.object(release, "resolve", return_value=PUBLISHED),
              patch.object(release, "api") as api):
            release.publish(TAG, COMMIT, PUBLISHED["id"])
        api.assert_not_called()

    def test_publish_checks_workflows_then_updates_exact_release(self):
        """Promote the staged ID only if the source is on main and workflow files match."""
        with (patch.object(release, "resolve", return_value=DRAFT),
              patch.object(release.subprocess, "run") as git,
              patch.object(release, "tag_commit", return_value=COMMIT),
              patch.object(release, "api", return_value=PUBLISHED) as api):
            git.return_value.returncode = 1
            with self.assertRaisesRegex(ValueError, "must still be on main"):
                release.publish(TAG, COMMIT, DRAFT["id"])
            api.assert_not_called()
            git.side_effect = [None, Mock(returncode=0), Mock(returncode=1)]
            with self.assertRaisesRegex(ValueError, "identical workflow files"):
                release.publish(TAG, COMMIT, DRAFT["id"])
            api.assert_not_called()
            git.side_effect = None
            git.return_value.returncode = 0
            release.publish(TAG, COMMIT, DRAFT["id"])
            api.assert_called_once_with("/releases/27", "--method", "PATCH", "-F", "draft=false",
                                        "-f", f"tag_name={TAG}", "-f", f"target_commitish={COMMIT}")

    def test_reread_draft_after_fetch(self):
        """A draft replaced while fetching main never reaches the publish endpoint."""
        replacement = dict(DRAFT, id=DRAFT["id"] + 1)
        with (patch.object(release, "resolve", side_effect=[DRAFT, replacement]),
              patch.object(release.subprocess, "run", return_value=Mock(returncode=0)),
              patch.object(release, "api") as api):
            with self.assertRaisesRegex(ValueError, "replaced"):
                release.publish(TAG, COMMIT, DRAFT["id"])
        api.assert_not_called()

    def test_swiftpm_lockfile_requires_both_version_and_commit(self):
        """A successful build with a different resolved revision fails the smoke test."""
        with tempfile.TemporaryDirectory() as directory:
            consumer = Path(directory)
            state = {"version": TAG[1:], "revision": COMMIT}
            lockfile = {"pins": [{"identity": "adaptivemodelrouting", "state": state}]}
            (consumer / "Package.resolved").write_text(json.dumps(lockfile))
            release.check_resolution(consumer, TAG, COMMIT)
            with self.assertRaisesRegex(ValueError, "did not resolve"):
                release.check_resolution(consumer, TAG, OTHER_COMMIT)
            with self.assertRaisesRegex(ValueError, "did not resolve"):
                release.check_resolution(consumer, "v0.3.0", COMMIT)
