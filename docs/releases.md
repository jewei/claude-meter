# Signed release verification

Releases require the local checks, Developer ID signing, Apple notarization, matching
app debug symbols, DMG integrity, and matching update-feed metadata. Manual platform and
live Sparkle update tests are optional for all releases, including major and migration
releases. No separate test host or report is required to publish or complete a release.

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

The script runs these steps:

1. Check that the worktree is clean, with no untracked files. Publishing also requires
   `HEAD` to equal the fetched `origin/main`. The script repeats this check before the
   archive and after artifact validation.
2. Build, sign, and notarize the app. Sign the DMG with the app signing identity, notarize
   and staple it, then let Sparkle sign the final bytes. Validation checks Gatekeeper and
   the stapled tickets on both containers.
3. Write the candidate feed under `build/`. After the checks pass, copy it into the
   release commit with the version and changelog, and push a staging branch.
4. Publish the GitHub release assets, including a versioned `.dSYMs.zip` whose symbol
   UUIDs match the shipped binary. Then push the feed to `main`.
5. Remove the staging branch and report completion.

The script does not wait for a report and never restores the feed automatically. Keep the
dSYM archive for crash analysis; the next release build replaces the local `build/`
directory.

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

This option stops after artifact validation and writes the candidate feed to
`build/appcast.xml`. It changes no version, changelog, feed, commit, tag, or Git ref, and
publishes nothing. The checkout must be clean but can differ from `origin/main`. Keep the
candidate artifacts private until publication is authorized.

## Optional manual checks

CI runs `verify-local.sh` on macOS 26. Its builds do not test runtime behavior on
macOS 14 or native Intel hardware. When test hosts are available, optional checks can
cover first launch, onboarding, the menu bar and popover, Settings, pause/resume,
display sleep/wake, and quit/relaunch. Use synthetic data for migration checks.

To test an actual Sparkle installation, use a separate macOS test account or VM
without real provider credentials. In that account's active desktop, run:

```bash
python3 scripts/sparkle-upgrade.py run \
  --previous-tag vPREVIOUS --version VERSION --build BUILD \
  --isolated-user TEST_USER --report /tmp/sparkle-upgrade.json
```

Replace each placeholder with the actual release or test-account value. The helper
uses the public feed, so this check runs after publication. It installs the previous
signed release. In Settings, select **Check for Updates**, then use Sparkle to install
and relaunch. The helper checks the version/build, signing, notarization, process
replacement, and continued execution. The report can be verified and attached to the
release for reference:

```bash
python3 scripts/sparkle-upgrade.py verify-report \
  --previous-tag vPREVIOUS --version VERSION --build BUILD \
  --feed appcast.xml --report /tmp/sparkle-upgrade.json
gh release upload vVERSION /tmp/sparkle-upgrade.json
```

Do not run the legacy `complete` helper command; it can restore the previous feed
automatically. Any feed recovery is a separate release decision.

The synthetic helper tests use temporary files and Git remotes. They remain in the
local check and do not launch a downloaded app.
