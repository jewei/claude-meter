# Signed release verification

Releases require the local checks, Developer ID signing, Apple notarization, matching
app and widget debug symbols, DMG integrity, and matching update-feed metadata.
A separate macOS test account, VM, or recorded Sparkle update test is not required for
this or future releases.

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

Add release notes under `[Unreleased]` in `CHANGELOG.md`, then run:

```bash
NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" \
  ./scripts/release.sh VERSION BUILD
```

Replace `VERSION` and `BUILD` with the target values. The build must be greater than
that in the public update feed. Omit `NOTARY_KEYCHAIN` to use the default Keychain
search. Set `KEYCHAIN_PROFILE` if the credentials use a profile other than `notarytool`.

The script builds, signs, notarizes, and validates the app and DMG. It commits the
version, changelog, and update feed, then pushes a staging branch. It publishes the
GitHub release assets before pushing the feed to `main`. It removes the staging branch
and reports completion. There is no upgrade-report wait, upload, or automatic feed
recovery in this release path.

If asset publication fails, the public feed stays on the previous release. If the feed
push fails, keep the signed assets and staging branch, resolve the push failure, and
retry the feed push. If only staging-branch removal fails, the release and feed are
already public; remove that branch after resolving the error. Retain `build/` and the
release output until publication is complete.

## Optional manual update check

The existing `scripts/sparkle-upgrade.py run` helper remains available for an optional
manual test. That helper still requires a fresh macOS test account or VM to protect live
provider data. Its report is not a release requirement. Do not run its legacy `complete`
command as part of publication; that command can restore the previous feed.

The synthetic helper tests use temporary files and Git remotes. They remain in the
local check and do not launch a downloaded app or contact GitHub.
