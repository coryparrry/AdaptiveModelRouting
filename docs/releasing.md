# Release AdaptiveModelRouting

Release Me uses Release Please to prepare a version and changelog PR from Conventional Commits on `main`. The first automated release starts from the existing `v0.1.0` tag and is expected to be `v0.2.0`.

## Prepare the release

1. In the repository's Actions settings, enable **Allow GitHub Actions to create and approve pull requests** so Release Please can open the PR. The workflow only creates or updates it. A maintainer uses **Approve workflows to run** on the bot PR if GitHub holds its checks for approval.
2. Review the generated version, changelog, and migration notes. Wait for Swift validation on the PR before merging it. Release Me creates a GitHub draft at the merged commit and waits for it to be published before proposing another version. The draft has no stable Git tag.
3. Run **Stage or publish Swift package** from `main` with the draft's tag and full commit SHA. Leave **Publish** unchecked to rehearse staging, including while the repository is private.

Staging runs the Xcode 27 suite on the exact draft commit. It covers Debug and Release tests, demo model tests, iOS cross-compilation, DocC, and documentation-comment coverage. The SwiftPM smoke test builds the single-import consumer pinned to the proposed version from a temporary Git repository and confirms the resolved commit.

GitHub runners need the Apple SDK to compile the adapter. All executable test flows, including demo tests that switch to Apple mode, use fixtures for inference. The consumer is compile-only. Hosted jobs require zero live Apple Intelligence or PCC calls and no Apple signing credentials.

## Publish and verify

The repository owner controls public visibility. Before making it public, review the source and history, PRs, and Actions logs that will become visible. The publish workflow requires the repository to be public.

After a successful rehearsal, run the same workflow from `main` with the same tag and full SHA and select **Publish**. The workflow repeats the staging checks, rechecks the draft and remote tag, and publishes the draft. Publication creates the stable Git tag that Xcode and SwiftPM use. The verification job independently resolves and builds that version from the public GitHub URL and compares the resolved commit to the staged commit.

If staging fails and the fix changes the source, merge the fix through the required checks on `main`. Confirm the release is still a draft and the version has no Git tag. Update the draft through the [GitHub Releases API](https://docs.github.com/en/rest/releases/releases#update-a-release). Send both the intended `tag_name` and the full fix commit SHA as `target_commitish`. GitHub can replace an omitted tag name with an `untagged-…` placeholder.

Confirm the updated release is still a draft with the intended tag name and target SHA, and that the Git tag is still absent. Review the draft notes and run staging with the new SHA. The manifest at the selected commit and on `main` must match the draft version.

A conflicting or orphaned tag stops the workflow for inspection. If publication succeeds and verification fails, rerun with the same tag and SHA to verify again. Published tags are immutable by convention. Release a newer version to correct a package defect.

After the first public release and a successful anonymous SwiftPM smoke test, submit the repository URL to the [Swift Package Index](https://swiftpackageindex.com/add-a-package) once. Subsequent versions use the same GitHub release flow.

## Qualify live Apple inference separately

Record live checks against the release SHA. On a supported Mac or physical iPhone with Apple Intelligence ready, a `.localOnly` generation and stream exercise the on-device path. Live PCC requires explicit opt-in, an entitled and signed consuming app, and a connection. Use synthetic prompts and record the requests made and their outcomes. Report any checks that were skipped or unavailable separately from hosted CI.
