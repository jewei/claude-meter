# Signed release verification

The local gate checks builds, tests, symbols, and synthetic upgrade-report fixtures.
It cannot prove that Sparkle can replace and relaunch a signed installed app.
Every published release therefore requires a recorded upgrade from the previous public
release before `scripts/release.sh` reports completion.

## Prepare the isolated desktop

Use a disposable macOS VM or a fresh, dedicated macOS user account. Log in to its GUI.
Install Python 3.9 or later and the Xcode command-line tools. Keep its clock synchronized
with the release machine. Do not configure Claude Code, Codex, Grok, or Cursor there.
The helper rejects root, a different console user, existing provider directories, and an
already running Claude Meter. These checks support isolation; they do not turn a daily-use
account into a disposable account.

Keep `scripts/sparkle-upgrade.py` available in this desktop before publishing. The script
copies only the previous signed app to a new directory under that user's `~/Applications`.
It does not replace `/Applications/ClaudeMeter.app`. It disables quota polling in the test
account. The app and report remain available for inspection. Reset the VM or remove the
disposable account after the check.

## Publish and test

Run the usual `scripts/release.sh VERSION BUILD` on the release machine. It captures the
public tag named by the current feed, builds and validates the signed artifacts, publishes the GitHub assets,
and then publishes the feed. It prints the required prior tag, target version, build, and
report destination. The release stays pending for up to 15 minutes. Set
`SPARKLE_UPGRADE_WAIT_SECONDS` before starting if the test environment needs more time.
There is no skip flag.

In the isolated desktop, use the values printed by the release command:

```bash
python3 scripts/sparkle-upgrade.py run \
  --previous-tag v2.16 --version 2.17 --build 200 \
  --isolated-user upgrade-test --report /tmp/ClaudeMeter-upgrade.json
```

The versions and build above are examples. The helper waits for the public feed to reach
the target, downloads the previous release, and checks its signature, signing team,
notarization, version, and build. It then launches that exact app path. In Claude Meter
Settings, select **Check for Updates**, then use Sparkle to install and relaunch. Do not
install or copy the target app manually. The helper does not download or install the target.
It checks the installed version and build, signature and notarization, then requires a
new process at that app path to stay running for five seconds. Its default live-check
window is 10 minutes. Pass `--team` if the release uses a different configured signing team.

Copy the JSON report to the destination printed on the release machine. Copy to a temporary
name first, then rename it into place, so the gate cannot read an incomplete transfer:

```bash
scp upgrade-test@TEST_HOST:/tmp/ClaudeMeter-upgrade.json build/upgrade.incoming
mv build/upgrade.incoming build/ClaudeMeter-VERSION-BUILD.upgrade.json
```

The release gate requires matching prior and target versions, a strictly newer build,
the exact feed hash and signing team, successful checks, a new process, and a report begun
after feed publication. It uploads the accepted report as a GitHub release asset, removes
the staging branch, and only then reports release completion. Reports contain no provider
credentials or home paths. Treat a report as an operator's test record, not independent
cryptographic proof of GUI actions.

## Failure and feed recovery

A failed, incomplete, wrong-release, or missing report fails release completion. The gate
fetches current `main` and restores only the prior `appcast.xml` in an isolated worktree.
It preserves later source commits and the release machine's local changes. It uses a normal
push. If the feed has already changed, or a concurrent push wins, recovery stops for review
instead of overwriting the newer feed.

A rejected report or timeout triggers this recovery automatically. If the process is
terminated before it can recover, run `build/complete-upgrade.sh`, which retains the original previous commit and report
inputs, or restore the previous feed through a reviewed commit. Check the public feed after recovery. Leave the signed release assets
and staging branch available for diagnosis. A feed rollback does not uninstall an update
that a user has already installed.

If report upload fails after a valid check, release completion also remains pending. The
valid feed stays in place. Retry `build/complete-upgrade.sh` with the same report. Retain the build directory and release command output until completion.

## Local fixtures

```bash
python3 scripts/test-sparkle-upgrade.py
```

These tests use synthetic reports and temporary local Git remotes. They cover invalid and
stale reports, exact feed matching, bounded file input, upload ordering, and feed recovery
with later commits and local changes. The shared `verify-local.sh` runs them in CI too.
They do not run Sparkle, launch a downloaded app, contact GitHub, or use signing credentials.
