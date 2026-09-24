# Signed release verification

Releases require the local checks, Developer ID signing, Apple notarization, matching
app debug symbols, DMG integrity, and matching update-feed metadata.
Major releases and changes to upgrade migrations require an actual signed Sparkle
installation and relaunch before release completion. Run that check in a separate
macOS test account or VM and retain its report. Other releases can use the lighter
artifact gate unless their changes require an update-path test.

## Prepare and publish

Run the full local check before a release:

```bash
./scripts/verify-local.sh
```

Store valid Apple notarization credentials in the Keychain. To use the login Keychain
explicitly:

```bash
xcrun notarytool store-credentials notarytool \
  --keychain "$HOME/Library/Keychains/login.keychain-db"
```

Add release notes under `[Unreleased]` in `CHANGELOG.md`. Commit and push all source
and documentation changes to `main`, then run:

```bash
NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" \
  ./scripts/release.sh VERSION BUILD
```

Replace `VERSION` and `BUILD` with the target values. The build must be greater than
that in the public update feed. Omit `NOTARY_KEYCHAIN` to use the default Keychain
search. Set `KEYCHAIN_PROFILE` if the credentials use a profile other than `notarytool`.

The script builds, signs, notarizes, and validates the app and DMG. It requires
source from a clean worktree, including no untracked files. Publishing requires `HEAD`
to equal the fetched `origin/main` commit. The script checks the same clean source
again before the archive and after artifact validation. It writes the candidate feed
under `build/` until those checks pass, then copies it into the release commit.
It uses the app signing identity for the DMG. It staples the DMG before Sparkle signs the final bytes.
Validation checks Gatekeeper and the stapled tickets for both containers. It commits the
version, changelog, and update feed, then pushes a staging branch. It publishes the
GitHub release assets before pushing the feed to `main`. It removes the staging branch
and reports completion for releases that do not require a live update test. For major
releases or changes to `*Migration.swift` or `LegacyClaudeFiles.swift`, the script instead
reports that verification is pending and retains the staging branch. Set
`REQUIRE_UPGRADE_TEST=1` for other changes to settings, storage or updater behavior that
need this check. The script does not wait for a report or automatically restore the feed.

If asset publication fails, the public feed stays on the previous release. If the feed
push fails, keep the signed assets and staging branch, resolve the push failure, and
retry the feed push. If only staging-branch removal fails, the release and feed are
already public; remove that branch after resolving the error. Retain `build/` and the
release output until publication is complete.

## Private candidate

Use the same workflow without publication:

```bash
./scripts/release.sh VERSION BUILD --prepare-only
```

This option writes the candidate feed to `build/appcast.xml`. It stops after artifact
validation. It does not change the project version, changelog or public feed, create a
commit or tag, push Git refs, or publish assets. It requires a clean candidate checkout,
but that checkout can differ from `origin/main`. Version and build arguments apply to
the archive. Keep the candidate
artifacts private until publication is authorized.

## Required runtime coverage

CI runs `verify-local.sh` on macOS 26. Its builds do not prove runtime behavior on
macOS 14 or native Intel hardware. Use a signed private candidate from the release
source commit for these checks before publishing:

| Environment | Required frequency |
| --- | --- |
| macOS 14, the oldest supported OS | Every release |
| Native Intel Mac running a supported macOS | Every major or migration release; at least once per calendar quarter that has a release |
| Current macOS on Apple Silicon | Every release |

One Intel Mac on macOS 14 can cover the first two rows. Rosetta is an additional check,
not evidence of a native Intel run. Use a separate test account or VM without real
provider credentials. Record the source commit, app version/build, DMG SHA-256, OS
version, native architecture, test date, and each result in a runtime report.

Check first launch and onboarding, the menu bar and popover, each Settings tab,
pause/resume, display sleep/wake, and quit/relaunch. Check missing or locked credentials
without unexpected Keychain prompts. For migration releases, use synthetic old settings
and event files; confirm owned data is removed and unrelated files remain. Never copy
live provider data into the test account. Rebuild and repeat affected checks if source
or build settings change after the candidate test. Attach the runtime report to the
release. A missing required environment leaves the release checks incomplete.

## Complete a required Sparkle update check

The release script publishes the signed asset before the feed. For major and migration
releases, publication does not mean verification is complete. Keep the staging branch
until the following steps pass. The existing helper uses the public feed, so this live
check runs after publication. It does not provide a pre-publication update gate.

In the fresh test account's active desktop, run:

```bash
python3 scripts/sparkle-upgrade.py run \
  --previous-tag vPREVIOUS --version VERSION --build BUILD \
  --isolated-user TEST_USER --report /tmp/sparkle-upgrade.json
```

Replace each placeholder with the actual release or test-account value. The helper
installs the previous signed release. In Settings, select **Check for Updates**, then
use Sparkle to install and relaunch. Do not manually replace the app. The helper checks
the new version/build, signing, notarization, process replacement and continued execution.
For migration releases, also retain the synthetic-data migration results from the runtime
check; a clean-account updater test alone does not exercise old stored data.

Copy the report to the release checkout, outside tracked source. Verify it against the
published feed, then attach it and the runtime report before removing the staging branch:

```bash
python3 scripts/sparkle-upgrade.py verify-report \
  --previous-tag vPREVIOUS --version VERSION --build BUILD \
  --feed appcast.xml --report /tmp/sparkle-upgrade.json
gh release upload vVERSION /tmp/sparkle-upgrade.json /tmp/runtime-smoke.md
git push origin --delete release-staging/vVERSION
```

Only then is the release complete. If a check fails, keep the staging branch, record the
failure and correct the release. Do not run the legacy `complete` helper command; it can
restore the previous feed automatically. Any feed recovery is a separate release decision.

The synthetic helper tests use temporary files and Git remotes. They remain in the
local check. They do not launch a downloaded app and do not replace the required live
installation or platform checks.
