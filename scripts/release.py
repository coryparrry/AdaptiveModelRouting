#!/usr/bin/env python3
"""Resolve, stage, publish, and verify the source version distributed through SwiftPM."""

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ".release-please-manifest.json"
INITIAL_TAG = "v0.1.0"
INITIAL_COMMIT = "9c18c6bcbce55df3a191d2b7cc9c91b9739e4ced"
TAG = re.compile(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
SHA = re.compile(r"[0-9a-f]{40}")


def api(path, *args, optional=False):
    """Call a repository GitHub endpoint, allowing only an explicit 404 as absence."""
    endpoint = f"repos/{os.environ['GITHUB_REPOSITORY']}{path}"
    result = subprocess.run(["gh", "api", endpoint, *args], text=True, capture_output=True)
    if result.returncode:
        if optional and result.stderr.rstrip().endswith("(HTTP 404)"):
            return None
        raise ValueError(f"GitHub request failed for {path}: {result.stderr.strip()}")
    return json.loads(result.stdout)


def manifest_tag(ref):
    """Read the root package version at an exact GitHub ref."""
    manifest = api(f"/contents/{MANIFEST}?ref={ref}", "-H", "Accept: application/vnd.github.raw+json")
    tag = f"v{manifest['.']}"
    if not TAG.fullmatch(tag):
        raise ValueError("The Release Please manifest must contain a stable version")
    return tag


def tag_commit(tag):
    """Resolve a GitHub tag and peel annotated tags to a commit."""
    ref = api(f"/git/ref/tags/{tag}", optional=True)
    if ref is None:
        return None
    target = ref["object"]
    while target["type"] == "tag":
        target = api(f"/git/tags/{target['sha']}")["object"]
    if target["type"] != "commit" or not SHA.fullmatch(target["sha"]):
        raise ValueError(f"{tag} must point to a commit")
    return target["sha"]


def find_release(tag):
    """Find an exact draft or published release, including drafts without a Git ref."""
    pages = api("/releases?per_page=100", "--paginate", "--slurp")
    matches = [release for page in pages for release in page if release["tag_name"] == tag]
    if len(matches) > 1:
        raise ValueError(f"Multiple GitHub releases match {tag}")
    return matches[0] if matches else None


def can_propose():
    """Allow the next release PR after the historical tag or a verified published release."""
    tag = manifest_tag("main")
    release = find_release(tag)
    if release is None and tag == INITIAL_TAG and tag_commit(tag) == INITIAL_COMMIT:
        return True
    if release and release["draft"]:
        print(f"{tag} is staged as a draft. Publish it before proposing another version.")
        return False
    if not release or release["prerelease"]:
        raise ValueError(f"{tag} is current on main but has no stable release; inspect Release Me before continuing")
    commit = tag_commit(tag)
    if commit is None or manifest_tag(commit) != tag:
        raise ValueError(f"{tag} does not resolve to a commit with the matching release manifest")
    return True


def require_release_pr(sha):
    """Require the draft source to be the merge commit of this repository's release PR."""
    repository = os.environ["GITHUB_REPOSITORY"]
    pulls = api(f"/commits/{sha}/pulls")
    if not any(pr["merged_at"] and pr["merge_commit_sha"] == sha
               and pr["base"]["ref"] == "main"
               and pr["head"]["repo"] and pr["head"]["repo"]["full_name"] == repository
               and pr["head"]["ref"].startswith("release-please--branches--main")
               for pr in pulls):
        raise ValueError(f"{sha} is not the merge commit of a Release Please PR into main")


def resolve(tag, sha, publishing=False):
    """Bind a current draft or prior publication to the supplied exact version and commit."""
    if not TAG.fullmatch(tag) or not SHA.fullmatch(sha):
        raise ValueError("Use a stable tag such as v0.2.0 and a full lowercase commit SHA")
    if publishing and api("")["visibility"] != "public":
        raise ValueError("Publishing requires a public repository. Use staging mode while it is private.")

    release = find_release(tag)
    commit = tag_commit(tag)
    if not release or release["prerelease"]:
        raise ValueError(f"{tag} must have a GitHub release draft or a stable publication")
    if not release["draft"]:
        if commit != sha:
            raise ValueError(f"Published tag {tag} does not resolve to {sha}")
        return release
    if commit is not None:
        raise ValueError(f"Draft {tag} already has a Git tag. Inspect it before publishing.")
    if release["target_commitish"] != sha or manifest_tag("main") != tag or manifest_tag(sha) != tag:
        raise ValueError(f"Draft {tag}, main, and release commit {sha} must agree")
    require_release_pr(sha)
    return release


def publish(tag, sha, release_id):
    """Recheck the staged draft and publish it by ID, or verify a successful prior attempt."""
    release = resolve(tag, sha, publishing=True)
    if release["id"] != release_id:
        raise ValueError("The release was replaced after staging")
    if not release["draft"]:
        return
    subprocess.run(["git", "fetch", "--no-tags", "origin", "main"], cwd=ROOT, check=True)
    ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", sha, "FETCH_HEAD"], cwd=ROOT)
    if ancestor.returncode:
        raise ValueError(f"Release commit {sha} must still be on main")
    differs = subprocess.run(["git", "diff", "--quiet", sha, "FETCH_HEAD", "--", ".github/workflows"], cwd=ROOT)
    if differs.returncode:
        raise ValueError("Unable to confirm the release and main have identical workflow files; inspect before publishing")
    release = resolve(tag, sha, publishing=True)
    if release["id"] != release_id:
        raise ValueError("The release was replaced after staging")
    if not release["draft"]:
        return
    release = api(f"/releases/{release_id}", "--method", "PATCH", "-F", "draft=false",
                  "-f", f"tag_name={tag}", "-f", f"target_commitish={sha}")
    if release["draft"] or release["tag_name"] != tag or tag_commit(tag) != sha:
        raise ValueError(f"GitHub publication could not be reconciled with {tag} at {sha}; inspect the release")
    print(release["html_url"])


def check_resolution(package, tag, sha):
    """Require the fresh SwiftPM lockfile to record the exact version and commit."""
    pins = json.loads((package / "Package.resolved").read_text())["pins"]
    if len(pins) != 1 or pins[0]["identity"] != "adaptivemodelrouting":
        raise ValueError("Expected exactly one AdaptiveModelRouting dependency")
    if pins[0]["state"] != {"version": tag[1:], "revision": sha}:
        raise ValueError(f"SwiftPM did not resolve {tag} at {sha}: {pins[0]['state']}")


def smoke(tag, sha, published=False):
    """Build the existing single-import consumer against a temporary or public Git tag."""
    if not TAG.fullmatch(tag) or not SHA.fullmatch(sha):
        raise ValueError("Specify a stable tag and full lowercase commit SHA")
    with tempfile.TemporaryDirectory(prefix="swiftpm-release-") as folder:
        temporary = Path(folder)
        if published:
            url = f"https://github.com/{os.environ['GITHUB_REPOSITORY']}.git"
        else:
            mirror = temporary / "AdaptiveModelRouting.git"
            subprocess.run(["git", "clone", "--quiet", "--bare", "--no-hardlinks", "--no-tags",
                            str(ROOT), str(mirror)], check=True)
            subprocess.run(["git", "--git-dir", str(mirror), "tag", tag, sha], check=True)
            url = mirror.as_uri()

        consumer = temporary / "Consumer"
        fixture = ROOT / "Tests" / "SingleImportConsumer"
        shutil.copytree(fixture / "Sources", consumer / "Sources")
        local_dependency = '.package(name: "AdaptiveModelRouting", path: "../..")'
        manifest = (fixture / "Package.swift").read_text()
        if manifest.count(local_dependency) != 1:
            raise ValueError("The single-import fixture no longer declares the expected local dependency")
        (consumer / "Package.swift").write_text(manifest.replace(
            local_dependency, f'.package(url: {json.dumps(url)}, exact: "{tag[1:]}")'))
        environment = dict(os.environ, GIT_TERMINAL_PROMPT="0")
        subprocess.run(["swift", "build", "-c", "release", "--package-path", str(consumer),
                        "--cache-path", str(temporary / "cache"), "--disable-sandbox"],
                       check=True, env=environment)
        check_resolution(consumer, tag, sha)
        print(f"SwiftPM built {tag} resolved at {sha}.")


def output(**values):
    """Expose verified metadata to dependent GitHub Actions jobs."""
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as stream:
        for key, value in values.items():
            print(f"{key}={value}", file=stream)


def main():
    """Run one release operation using validated arguments and the job's permissions."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("can-propose")
    for name in ("resolve", "publish", "smoke"):
        command = commands.add_parser(name)
        command.add_argument("tag")
        command.add_argument("sha")
    commands.choices["resolve"].add_argument("--publish", action="store_true")
    commands.choices["publish"].add_argument("release_id", type=int)
    commands.choices["smoke"].add_argument("--published", action="store_true")
    args = parser.parse_args()
    try:
        match args.command:
            case "can-propose":
                output(ready=str(can_propose()).lower())
            case "resolve":
                release = resolve(args.tag, args.sha, publishing=args.publish)
                output(release_id=release["id"], draft=str(release["draft"]).lower())
            case "publish":
                publish(args.tag, args.sha, args.release_id)
            case "smoke":
                smoke(args.tag, args.sha, published=args.published)
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
