# Releasing

One command builds, signs, notarizes, and publishes a release. Only the maintainer runs it,
on a Mac that has the credentials below. Releases are not made in CI.

## One-time setup

Do these steps once on each Mac that makes releases.

1. **Developer ID certificate.** The login Keychain must have the identity
   `Developer ID Application: Jewei Mak (4L4SS26L9J)` with its private key. To check:

   ```bash
   security find-identity -v -p codesigning
   ```

   To get one, use Xcode (Settings, Accounts, Manage Certificates) or the Apple Developer
   web site. Keep a backup: export the identity from Keychain Access as a `.p12` file with a
   strong password, and store it offline.

2. **Notarization credentials.** Store them in the Keychain under the profile name
   `notarytool`:

   ```bash
   xcrun notarytool store-credentials notarytool \
       --apple-id "<Apple ID>" --team-id 4L4SS26L9J --password "<app-specific password>"
   ```

   Make the app-specific password at account.apple.com. An App Store Connect API key also
   works (`--key`, `--key-id`, `--issuer`). If you use another profile name, set
   `NOTARY_PROFILE`. If the profile is not in the default Keychain, set `NOTARY_KEYCHAIN`
   to the Keychain path, for example `$HOME/Library/Keychains/login.keychain-db`.

3. **Sparkle EdDSA key.** The private key is in the login Keychain (service
   `https://sparkle-project.org`, account `ed25519`). Every installed copy of Claude Meter
   checks each update with the matching public key, `SUPublicEDKey` in `App/Info.plist`.
   Run `make app` once, so that the Sparkle tools are in `build/SourcePackages`. Then
   check that the keys match:

   ```bash
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -p
   ```

   The output must be `Ns9aeDpiL/p7DCVX4TRw4OnqkmZs0y6+7afPO+i1vPM=`.

   **Back up the private key.** Without it, you cannot publish an update that installed
   copies accept. Export it, store the file offline (for example in a password manager),
   then delete the file:

   ```bash
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
   ```

   To install the key on another Mac, use `generate_keys -f sparkle-private-key.txt`. Never
   commit the file. Sparkle lets one update change the EdDSA key or the Developer ID
   certificate, but not both.

4. **GitHub CLI.** Run `gh auth login` with access to `jewei/claude-meter`.

## Make a release

1. Add the release notes under `## [Unreleased]` in `CHANGELOG.md`. Use `### Added`,
   `### Changed`, `### Fixed`, and `### Removed` headings and `- ` list items. The notes
   become the GitHub release text and the HTML text in the Sparkle update window.
2. Commit and push everything to `main`. Make sure that CI passes.
3. Select the version and the build number (see [The build number](#the-build-number)).
4. Optional: make a private candidate first. This works on any branch:

   ```bash
   scripts/release.sh 4.0.0 400 --prepare-only
   ```

5. Publish:

   ```bash
   make release VERSION=4.0.0 BUILD=400
   ```

The release takes about 10 to 20 minutes. Most of the time is Apple notarization.

## What the script does

`scripts/release.sh VERSION BUILD [--prepare-only]` does these steps in this order. Each
step prints `==> <step>`.

1. **Check preconditions.** VERSION is 4.x. The working tree is clean, with no untracked
   files. When it publishes: the branch is `main`, `HEAD` equals the fetched `origin/main`,
   and tag `vVERSION` does not exist. BUILD is greater than every `sparkle:version` in
   `appcast.xml`. `CHANGELOG.md` has a `## [Unreleased]` section that is not empty. The
   signing identity, the notarization profile, and the Sparkle key are present.
2. **Run `make check`.** The same gate as CI.
3. **Archive and export with Developer ID.** A universal Release archive in
   `build/release`, with the version and build from the command line. The export uses
   `scripts/ExportOptions.plist` and signs Sparkle's helpers again.
4. **Notarize and staple the app.**
5. **Create, sign, notarize, and staple the DMG.** The DMG holds `ClaudeMeter.app` and a
   link to `/Applications`.
6. **Sign the DMG for Sparkle** with `sign_update` from `build/SourcePackages`, the
   package version that the project pins.
7. **Validate the artifacts:** `codesign --verify --deep --strict`, the team identifier,
   `spctl` for the app and the DMG, `stapler validate` for both, `sign_update --verify`, the
   DMG length, the app version and build, and the dSYM UUIDs against the app binary. Then
   it zips the dSYMs.
8. **Write the candidate feed** to `build/release/appcast.xml`. It adds one item above the
   newest item and keeps all existing items. The item has the version, the build, the
   minimum macOS version from the app, `minimumUpdateVersion` 295, the HTML release notes,
   the DMG URL, the length, and the EdDSA signature.

With `--prepare-only` the script stops here. It changes no tracked file and publishes
nothing. Without it, it continues:

9. **Commit and tag the release.** It copies the feed to `appcast.xml`, promotes
   `[Unreleased]` in `CHANGELOG.md` to the version and date, writes the version and build
   into `Config/Version.xcconfig`, commits `Release vVERSION`, and makes the tag.
10. **Publish the GitHub release.** It pushes the tag, then runs
    `gh release create --verify-tag` with the DMG and the dSYM zip.
11. **Publish the feed.** It pushes `main`. Installed apps read the feed from `main`, so
    they see the new item only after the DMG is on GitHub.

Output stays in `build/release`. Keep the dSYM zip until the next release. The GitHub
release also has a copy.

## The build number

`CFBundleVersion` is an integer build number. Sparkle compares it with `sparkle:version` in
the feed to find an update. These rules apply:

- Every release must have a build number greater than every build in `appcast.xml`. The
  script stops if it is not. The last 3.x release, 3.1.3, is build 337.
- The 4.x line starts at 400. Increase the number by at least one for each release, for
  example 4.0.1 is 401.
- Do not use the Git commit count. The 4.x history has fewer commits than 3.x had, so
  the count is smaller than 337, and no installed app would see the update.
- A build number that the script used for a candidate that was not published can be
  used again.

## The minimumUpdateVersion gate

Every 4.x item in the feed has `<sparkle:minimumUpdateVersion>295</sparkle:minimumUpdateVersion>`.
295 is the build number of 3.0. Sparkle 2.9 and later removes an item from consideration
when the installed build is lower than this value. Every published Claude Meter has
Sparkle 2.9.3 or later.

- A 2.x install (build lower than 295) does not see 4.x. It gets the newest 3.x item,
  3.1.3. 3.1.3 runs the 2.x migrations. On the next check, it sees 4.x.
- A 3.x install sees 4.x at once.

Keep the 3.1.3 item in `appcast.xml` for as long as 2.x installs can exist. Do not remove
old items, and do not delete a release asset that the feed names.

The script accepts only 4.x versions. Before a 5.0 release, decide the gate for 5.x, then
change `MINIMUM_UPDATE_BUILD` and the version check in `scripts/release.sh`.

To test the gate before you publish, use a separate macOS user account or a virtual
machine with an older release installed. Upload the candidate feed to an HTTPS location,
then point the old install at it:

```bash
defaults write com.jewei.claudemeter SUFeedURL "https://<your test location>/appcast.xml"
```

Select Check for Updates. Remove the override after the test:
`defaults delete com.jewei.claudemeter SUFeedURL`.

## Recovery

When a step fails, the script names the step, shows the failed command, and says what is
already public. Find the last step that started, then do the related procedure.

**Steps 1 to 8 (before "Commit and tag the release").** Nothing changed outside
`build/release`. Correct the cause and run the script again. If notarization failed, the
script prints Apple's log above the error.

**Step 9, "Commit and tag the release".** The commit and the tag exist only on this Mac.
Remove them, then run the script again:

```bash
git tag -d vVERSION
git reset --hard origin/main
```

The tree was clean before the script started, so this removes only the release commit.

**Step 10, "Publish the GitHub release".** If the tag push failed, do the step 9 procedure.
If the tag is on GitHub but the release is not, finish the release by hand:

```bash
gh release create vVERSION build/release/ClaudeMeter-VERSION.dmg \
    build/release/ClaudeMeter-VERSION-BUILD.dSYMs.zip --repo jewei/claude-meter \
    --verify-tag --title "Claude Meter VERSION" --notes-file build/release/release-notes.md
git push origin HEAD:main
```

To cancel the release instead, remove the tag on GitHub and on this Mac, then do the step 9
procedure:

```bash
git push origin :refs/tags/vVERSION
```

**Step 11, "Publish the feed".** The GitHub release is public, but installed apps do not
see it yet. This is safe. Push again:

```bash
git push origin HEAD:main
```

If `main` moved, run `git pull --rebase origin main`, make sure that the new item is still
the first item in `appcast.xml`, and push.

**A bad release after publication.** Publish a corrected release with a higher build
number. To stop more installs at once, remove the bad item from `appcast.xml` in a commit
on `main`. Copies that already updated stay on the bad release until the next one.
