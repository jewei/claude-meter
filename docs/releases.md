# Prepare and publish a signed release

Complete the local checks before publication. The release script checks the Developer ID
signature, Apple notarization, app debug symbols, DMG integrity, and update-feed
metadata. Manual platform tests and live Sparkle update tests are optional, including
for major releases and migrations. Publication requires no separate test host or report.

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

Add release notes under `[Unreleased]` in `CHANGELOG.md`. Commit all source and
documentation changes. Push the commit to `main`. Then run the release script:

```bash
NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" \
	./scripts/release.sh VERSION BUILD
```

Replace `VERSION` and `BUILD` with the target values. The build must be greater than
that in the public update feed. Omit `NOTARY_KEYCHAIN` to use the default Keychain
search. Set `KEYCHAIN_PROFILE` if the credentials use a profile other than `notarytool`.

The script completes these steps:

1. Checks that the worktree is clean, with no untracked files. Publication also requires
   `HEAD` to equal the fetched `origin/main`. The script repeats this check before the
   archive and after artifact validation.
2. Builds, signs, and notarizes the app. It signs the DMG with the app signing identity,
   then notarizes and staples the DMG. Sparkle signs the final bytes. Validation checks
   Gatekeeper and the stapled tickets on both containers.
3. Writes the candidate feed under `build/`. After validation, it commits the feed,
   version, and changelog, then pushes a staging branch.
4. Publishes the GitHub release assets. These include a versioned `.dSYMs.zip` whose
   symbol UUIDs match the shipped binary. It then pushes the feed to `main`.
5. Removes the staging branch and reports completion.

The script does not wait for a report and never restores the feed automatically. Keep
the dSYM archive for crash analysis. The next release build replaces the local `build/`
directory.

If asset publication fails, the public feed stays on the previous release. If the feed
push fails, keep the signed assets and staging branch, resolve the push failure, and
retry the feed push. If only staging-branch removal fails, the release and feed are
already public. Resolve the error before you remove that branch. Retain `build/` and the
release output until publication is complete.

## Prepare a private candidate

Use the same workflow without publication:

```bash
./scripts/release.sh VERSION BUILD --prepare-only
```

This option stops after artifact validation and writes the candidate feed to
`build/appcast.xml`. It changes no version, changelog, feed, commit, tag, or Git ref,
and publishes nothing. The checkout must be clean but can differ from `origin/main`.
Keep the candidate artifacts private until publication is authorized.

## Run optional manual checks

CI runs `verify-local.sh` on macOS 26. Its builds do not test runtime behavior on macOS
14 or native Intel hardware. When test hosts are available, optional checks can cover
first launch, onboarding, the menu bar, the popover, and Settings. Also check pause,
resume, display sleep, wake, quit, and relaunch. Use synthetic data for migration
checks.

To test an actual Sparkle installation, use a separate macOS test account or VM without
real provider credentials. In that account's active desktop, run:

```bash
python3 scripts/sparkle-upgrade.py run \
	--previous-tag vPREVIOUS --version VERSION --build BUILD \
	--isolated-user TEST_USER --report /tmp/sparkle-upgrade.json
```

Replace each placeholder with the actual release or test-account value. The helper uses
the public feed, so this check runs after publication. It installs the previous signed
release. In Settings, select **Check for Updates**, then use Sparkle to install and
relaunch. The helper checks the version, build, signature, notarization, process
replacement, and continued execution. To verify and attach the report, run these
commands:

```bash
python3 scripts/sparkle-upgrade.py verify-report \
	--previous-tag vPREVIOUS --version VERSION --build BUILD \
	--feed appcast.xml --report /tmp/sparkle-upgrade.json
gh release upload vVERSION /tmp/sparkle-upgrade.json
```

The legacy `complete` helper command can restore the previous feed automatically. Do not
run that command. Treat feed recovery as a separate release decision.

The synthetic helper tests use temporary files and Git remotes. They remain in the local
check and do not launch a downloaded app.
