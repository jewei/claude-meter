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
   strong password to a folder outside this repository, and store it offline.

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
   copies accept. Export it only to an encrypted location, such as an encrypted disk image.
   `rm` does not erase file contents on macOS, so never export it to a plain folder. Store
   the file offline (for example in a password manager), then delete the image:

   ```bash
   hdiutil create -size 10m -fs APFS -encryption AES-256 -volname "Sparkle key" ~/sparkle-key.dmg
   hdiutil attach ~/sparkle-key.dmg
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x "/Volumes/Sparkle key/sparkle-private-key.txt"
   # Store the file in your password manager, then:
   hdiutil detach "/Volumes/Sparkle key" && rm ~/sparkle-key.dmg
   ```

   To install the key on another Mac, use `generate_keys -f <file>`. Never put the file in
   this repository; `.gitignore` also refuses `sparkle-private-key*`, `*.p12`, and `*.p8`.
   Sparkle lets one update change the EdDSA key or the Developer ID certificate, but not
   both.

4. **GitHub CLI.** Run `gh auth login` with access to `jewei/claude-meter`.

## Make a release

1. Add the release notes under `## [Unreleased]` in `CHANGELOG.md`. Use `### Added`,
   `### Changed`, `### Fixed`, and `### Removed` headings and `- ` list items. The notes
   become the GitHub release text and the HTML text in the Sparkle update window. Each
   entry describes a change against the last release, never a fix of unreleased code.
2. **TODO before 4.0.0:** the screenshots in `README.md`
   (`docs/images/claude-meter-light-mode.png` and `docs/images/claude-meter-dark-mode.png`)
   show the 2.x popover. Capture the 4.0 popover in light mode and in dark mode, replace the
   two files, and remove this step.
3. Commit and push everything to `main`. Make sure that CI passes.
4. Select the version and the build number (see [The build number](#the-build-number)).
5. Optional: make a private candidate first. It uploads to Apple notarization, but publishes
   nothing. This works on any branch:

   ```bash
   make release-candidate VERSION=4.0.0 BUILD=400
   ```

   For a release that changes Keychain or credential code, open the candidate on a Mac
   where Claude Code is signed in. Open **Settings > Data** and confirm that no Keychain
   dialog appears before you select **Connect automatically**. Tests cannot show a system
   dialog, so this is the only check of the no-prompt rule.

6. Publish:

   ```bash
   make release VERSION=4.0.0 BUILD=400
   ```

The release takes about 10 to 20 minutes. Most of the time is Apple notarization.

## What the script does

`scripts/release.sh VERSION BUILD [--prepare-only]` does these steps in this order. Each
step prints `==> <step>`.

1. **Check preconditions.** VERSION is 4.x. BUILD passes the checks in
   [The build number](#the-build-number). If `IGNORE_SKIPPED_UPGRADES_BELOW` is set, it is a
   build from 401 to BUILD. The working tree is clean, with no untracked files. When it
   publishes: the branch is `main`, `HEAD` equals the fetched `origin/main`, tag `vVERSION`
   is neither on this Mac nor on GitHub, and `gh auth status` succeeds. `CHANGELOG.md` has a
   `## [Unreleased]` section that is not empty and has no `]]>`.
   `ClaudeMeterUpdateRequirement` in `App/Info.plist` compiles with `csreq`. The signing
   identity, the notarization profile, and the Sparkle key are present.
2. **Run `make check`.** The same gate as CI, including an unsigned Release build.
3. **Archive and export with Developer ID.** A universal Release archive in
   `build/release`, with the version and build from the command line. The export uses
   `scripts/ExportOptions.plist` and signs Sparkle's helpers again.
4. **Notarize and staple the app.**
5. **Create, sign, notarize, and staple the DMG.** The DMG holds `ClaudeMeter.app` and a
   link to `/Applications`.
6. **Sign the DMG for Sparkle** with `sign_update` from `build/SourcePackages`, the
   package version that the project pins.
7. **Validate the artifacts:** `codesign --verify --deep --strict`, the app's own update
   requirement (`ClaudeMeterUpdateRequirement` in Info.plist; an app that fails it never
   updates), the team identifier, `spctl` for the app and the DMG, `stapler validate` for
   both, `sign_update --verify`, the DMG length, the app version and build, the dSYM UUIDs
   against the app binary, and the app inside the mounted DMG with its `Applications`
   link. Then it zips the dSYMs.
8. **Write the candidate feed** to `build/release/appcast.xml`. It adds one item above the
   newest item and keeps all existing items. The item has the version, the build, the
   minimum macOS version from the app, `minimumUpdateVersion` 295,
   `minimumAutoupdateVersion` 400, `ignoreSkippedUpgradesBelowVersion` if
   `IGNORE_SKIPPED_UPGRADES_BELOW` is set, the HTML release notes, the DMG URL, the length,
   and the EdDSA signature.

With `--prepare-only` the script stops here. It changes no tracked file and publishes
nothing. Without it, it continues:

9. **Commit and tag the release.** It stops if `HEAD` changed during the build. It copies the
   feed to `appcast.xml`, promotes `[Unreleased]` in `CHANGELOG.md` to the version and date,
   writes the version and build into `Config/Version.xcconfig`, commits `Release vVERSION`,
   and makes the tag.
10. **Publish the GitHub release.** It pushes the tag, then runs
    `gh release create --verify-tag` with the DMG and the dSYM zip.
11. **Publish the feed.** It pushes `main`. Installed apps read the feed from `main`, so
    they see the new item only after the DMG is on GitHub.

Output stays in `build/release`. Keep the dSYM zip until the next release. The GitHub
release also has a copy.

## The build number

`CFBundleVersion` is an integer build number. Sparkle compares it with `sparkle:version` in
the feed to find an update.

The script checks these rules in step 1, and stops if BUILD breaks one of them:

- BUILD is a positive integer, 400 or greater. The 4.x line starts at 400
  (`MAJOR_START_BUILD` in `scripts/release.sh`).
- BUILD is greater than every build in `appcast.xml`. The last 3.x release, 3.1.3, is
  build 337.
- BUILD is not lower than `CURRENT_PROJECT_VERSION` in `Config/Version.xcconfig`. The
  release commit writes the released version and build into that file. If the tag of the
  file's `MARKETING_VERSION` exists, that build is published, and BUILD must be greater. So
  a build is never used twice, even after its item leaves the feed. Before the first 4.x
  release, the file has 4.0.0 and 400, and tag `v4.0.0` does not exist, so 4.0.0 can use
  400.

You choose the number. The script cannot check these rules:

- Choose a number that is easy to match to the version, for example 401 for 4.0.1.
- Do not use the Git commit count as the build number. The count depends on how branches
  merge.
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

Every 4.x item also has `<sparkle:minimumAutoupdateVersion>400</sparkle:minimumAutoupdateVersion>`.
4.0 starts with fresh settings, so a 3.x install always shows the update window with the
release notes, even when the user chose automatic installs. 4.x installs keep updating
silently.

All 4.x items share this `minimumAutoupdateVersion`, so for a 3.x install each one is the
same major upgrade. When a 3.x user selects **Skip This Version** on a 4.x item, Sparkle
records 400 and the build of that item. After that, scheduled checks skip every 4.x item,
also the later ones. Only **Check for Updates** still shows them. To show a release to these
users again, set `IGNORE_SKIPPED_UPGRADES_BELOW` to a build from 401 to BUILD:

```bash
make release VERSION=4.1.0 BUILD=410 IGNORE_SKIPPED_UPGRADES_BELOW=410
```

The item then has `<sparkle:ignoreSkippedUpgradesBelowVersion>` with that build. A user who
skipped a 4.x build lower than it sees the item in scheduled checks again. Sparkle 2.9.3
supports this element.

Keep the 3.1.3 item in `appcast.xml` for as long as 2.x installs can exist. Do not remove
old items, except in the maintainer's bad-release procedure (see [Recovery](#recovery)), and
do not delete a release asset that the feed names.

The script accepts only 4.x versions. Before a 5.0 release, decide the gate for 5.x, then
change `MINIMUM_UPDATE_BUILD`, `MAJOR_START_BUILD`, and the version check in
`scripts/release.sh`.

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

**Steps 1 to 8 (before "Commit and tag the release").** No tracked file changed and nothing
was published. Correct the cause and run the script again. If notarization failed, the
script prints Apple's log above the error.

**Step 9, "Commit and tag the release".** Read the last line of the script's output.

- **"Nothing was published."** `HEAD` changed during the build, so the script stopped before
  it changed a file. Do not reset: a reset removes the commits that moved `HEAD`. Check out
  `main` at the commit to release, then run the script again. Step 1 requires that `main`
  equals `origin/main`, so push new commits first and make sure that CI passes.
- **Any other message.** Tracked files, and maybe the release commit and the tag, exist only
  on this Mac. Remove them with the step 9 reset, then run the script again:

  ```bash
  git tag -d vVERSION
  git reset --hard origin/main
  ```

  When the script started, the tree was clean and `HEAD` was equal to `origin/main`. The
  script makes the release commit only when `HEAD` has not changed since then, so this
  removes only the release commit and its file changes.

**Step 10, "Publish the GitHub release".** If the tag push failed, do the step 9 reset.
If the tag is on GitHub, first check whether GitHub made the release or a draft:

```bash
gh release view vVERSION --repo jewei/claude-meter --json isDraft,assets
```

If a draft exists, upload what is missing with `gh release upload vVERSION <files>
--clobber`, publish it with `gh release edit vVERSION --draft=false`, and push `main`. If no
release exists, finish it by hand:

```bash
gh release create vVERSION build/release/ClaudeMeter-VERSION.dmg \
    build/release/ClaudeMeter-VERSION-BUILD.dSYMs.zip --repo jewei/claude-meter \
    --verify-tag --title "Claude Meter VERSION" --notes-file build/release/release-notes.md
git push origin HEAD:main
```

To cancel the release instead, remove the tag on GitHub, then do the step 9 reset, which
also removes the tag on this Mac:

```bash
git push origin :refs/tags/vVERSION
```

**Step 11, "Publish the feed".** The GitHub release is public, but installed apps do not
see it yet. This is safe. Push again:

```bash
git push origin HEAD:main
```

If `main` moved, merge, do not rebase: the tag must stay on a commit that `main` contains.
Run `git pull --no-rebase origin main`, make sure that the new item is still the first
item in `appcast.xml`, and push.

**A bad release after publication.** Publish a corrected release with a higher build
number. To stop more installs at once, remove the bad item from `appcast.xml` in a commit
on `main`. This is the only time a person edits `appcast.xml`, and only the maintainer does
it. Copies that already updated stay on the bad release until the next one.

**Two valid Developer ID certificates.** During a certificate renewal, `codesign --sign
"Developer ID Application: …"` stops with "ambiguous". Set `SIGNING_IDENTITY` to the SHA-1
of the new certificate (`security find-identity -v -p codesigning`), or remove the old one
from the Keychain before you release.
