# Claude Meter — Architecture Revamp Plan

## Progress

Phases 1 through 12A are complete. Phase 12B produced a private signed and notarized
3.0 candidate. Automated and live-provider checks pass. Isolated clean-install and
actual Sparkle-upgrade validation remain blocked because no test account or VM is available.
Notifications, analytics, status monitoring, forecasts, the widget and the statusline
source are removed. Claude uses OAuth. Optional Claude web reset offers are also removed.

All four providers now publish normalized account/window/balance readings through
UsageStore. RefreshScheduler owns global timing and admission. AppState retains
presentation, settings and application coordination.
Claude and Codex retain their provider-owned persistence formats. Codex now prefers direct
OAuth with one-shot credential recovery. Codex remains the credential owner. Cursor reads
its database through system SQLite without a subprocess or credential detection cache. Refresh uses one five-minute interval, freshness checks on open/wake, and no asleep timer.

## Phase 12B: private release candidate validation, 2026-09-23

### Candidate and environment

- Version **3.0**, build **295**, bundle ID `com.jewei.claudemeter`.
- Private candidate commit `c4441cfdcb83a18817ac02de347e60bf031c80ee`.
  The final checks and archive used a clean private checkout. It includes the existing
  phase changes from the development working tree. That working tree was preserved.
- Last public release: **2.18**, build **292**. Its downloaded app passed signature,
  stapled-ticket and Gatekeeper checks. Its update public key matches the candidate.
- Xcode 27.0, build 27A266a; macOS 27.0, build 26A428; arm64 MacBook Air, Mac14,2.
  The Release app contains arm64 and x86_64 code. Only arm64 was run. Older supported
  macOS versions and Intel execution remain untested here.
- Developer ID Application signing, team `4L4SS26L9J`. Personal certificate details
  are omitted. All six executable components have valid signatures and hardened runtime.
  None has `get-task-allow`. The app has no App Group entitlement or widget extension.
- Final DMG: `ClaudeMeter-3.0.dmg`, **4,321,576 bytes**.
  SHA-256: `cbd8e4ab9b778ef762cc7692c82dcf2b4f9adc4516f4661283e5148941792c09`.
  Artifacts, symbols and raw build output are outside the repository in the private
  validation directory. No tag, GitHub release, public appcast or production asset was published.

### Concrete fixes

1. The former workflow signed and notarized the app, but left the user-facing DMG
   unsigned and unstapled. Gatekeeper rejected that DMG. The workflow now signs the
   DMG with the exported app's certificate, notarizes it, and staples it before
   Sparkle signs its final bytes. The validator checks both containers.
2. `release.sh VERSION BUILD --prepare-only` uses the existing release workflow and
   stops before repository mutation or publication. Its candidate feed goes into
   `build/`. Script tests cover the stop point and signing order.
3. First popover open produced four SwiftUI faults about publication during a view
   update. Symbolication identified `PopoverWindowCaptureView.viewDidMoveToWindow`.
   Window notifications now run after the current update, coalesce, and use the latest
   attachment and callback. Two tests failed before the fix and passed after it.
   Both subsequent signed-app runs, including the exact final package, logged zero such faults.
4. Settings text now states the actual Claude account-pin/nearest-limit rule. The
   obsolete claim about the most recently used account was removed. Selection behavior
   did not change. Project version/build metadata is now 3.0/295.

No provider, authentication, persistence, scheduler or migration behavior changed.

### Release gates

| Area | Result | Evidence and limits |
| --- | --- | --- |
| Automated verification | PASS | 101 Core, 334 provider and 90 app tests; formatting, script fixtures, unsigned Debug/Release builds |
| Signed Release | PASS | Archive and Developer ID export through the existing release script; six signed executable components |
| Notarization | PASS | Final app ZIP and final distribution DMG accepted; both Apple logs have no issues |
| Gatekeeper | PASS | App execution assessment and DMG primary-signature assessment pass; tickets validate on app, DMG and mounted app |
| Sparkle integrity | PASS | Sparkle 2.9.3; archive signature verified by `sign_update` and independently against the app's embedded key; modified bytes rejected |
| Sparkle installation | BLOCKED | No separate macOS account or VM was available. A private loopback feed/download preserved the final DMG hash and signature, but no updater install/relaunch was performed |
| Clean installation | BLOCKED | No isolated desktop was available. Onboarding and empty-storage behavior passed fixtures, but a genuinely clean app installation was not run |
| Last-release upgrade | BLOCKED | 2.18/292 was downloaded and validated; settings were used in live smoke tests, but a complete isolated 2.18-to-3.0 installation/migration was not run |
| Legacy migrations | PASS WITH DOCUMENTED GAP | Isolated fixtures cover hooks, captures, snapshot import, obsolete caches, neighbors and retry. Signed-app execution against a real legacy container remains untested |
| Claude | PASS WITH DOCUMENTED GAP | Live OAuth success after the user connected; one account, plan and usage shown. Multi-account and optional fields have integration coverage |
| Codex | PASS WITH DOCUMENTED GAP | Live direct OAuth with one home; usage shown; no child observed. Multi-home and one-shot recovery were integration-tested, not forced on live credentials |
| Cursor | PASS | Live SQLite/WAL credentials and usage; no sqlite3 child. Main DB bytes and mtime unchanged in the comparison. Cursor was running, so changing WAL/SHM metadata cannot be attributed to this app; isolated read-only tests passed |
| Grok | PASS WITH DOCUMENTED GAP | Live success and credit usage shown. Conditional balance fields are covered by normalization tests when the live account does not supply them |
| Popover and Settings | PASS | Labels/cards, local time updates, open/close, Settings tabs and corrected account guidance observed |
| Launch/quit | PASS | Launch, normal quit, quit near startup refresh and relaunch succeeded; current Claude JSON and Codex schema-2 archive remained readable |
| Sleep/wake | PASS WITH DOCUMENTED GAP | Deterministic scheduler tests pass. Physical sleep was not forced on the primary interactive desktop |
| Privacy/package | PASS | No credentials/private keys or development artifacts found in the app. Observed runtime messages had no token, bearer, email or private-home pattern matches |
| Runtime sanity | PASS | Near-zero closed CPU, stable short-sample RSS, no children, fresh-open request suppression and scheduled background work observed |

### Upgrade and lifecycle evidence

The legacy fixture suite runs attention cleanup, statusline cleanup, App Group snapshot
import, then final artifact cleanup. It preserves unrelated hooks, settings and files.
Malformed import and filesystem-failure cases keep the prerequisite source and leave
completion unset. A later successful attempt completes import and cleanup. All four
versioned keys remain unchanged. Shared-default files and generic temporary-store files
remain untouched.

Live smoke tests used temporary process arguments to skip these migrations in the
primary account. The arguments did not set persistent completion flags. Provider
configuration, account names/plans and account pins matched their pre-test values.
The installed 2.18 app was restored after the private candidate tests. These checks
are not a substitute for the blocked installation tests above.

Provider disable/re-enable, manual refresh, account pins, missing pins, nearest-limit
selection, stale retention, cancellation and failure isolation passed existing store,
scheduler and app tests. Live isolation was also observed when Claude initially had no
usable reading while Codex, Cursor and Grok remained available. After connection, all
four produced live readings. No credentials were deliberately invalidated for testing.
No live auth-recovery or multi-account switch was forced.

### Network and runtime check

A signed build with the popover fix made four HTTP 200 requests at launch. Fresh
popover opens at about 12 and 52 seconds made no requests. An old-reading open at
82 seconds made four HTTP 200 requests. Settings opening produced one further HTTP
200 request; that request was not attributed to a provider. It is recorded separately
from the popover freshness result.

The exact final package repeated live success for all four providers, fresh-open
suppression, Settings opening and normal quit. Its visible local age label changed
from 10 to 13 seconds with no intervening HTTP request. No SwiftUI runtime fault occurred.

The longer sample observed the normal scheduled cycle at about 320 seconds against the
configured 300-second interval. This is a coalesced timer, not a real-time deadline.
There was no one-minute background request cycle. That sample preceded the final text
correction; scheduling and provider code were identical.

With all four providers enabled, closed samples averaged **0.010%** and **0.011%** CPU
for 17 and 20 seconds. RSS was **110.9–113.3 MiB** and stable after the visible UI work.
The sampler checked direct children every 200 ms and observed none. This is a short
sanity check, not a leak study or a guarantee that sampling catches every brief process.
Provider tests also prove that healthy Codex does not call its recovery source and that
Cursor has no process path. Codex auth-file bytes were unchanged during the live comparison.

The initial SwiftUI publication fault was fixed. Idle TCP close/timeout messages occurred
alongside successful HTTP results and caused no observed provider failure. Xcode emitted
platform/destination warnings, and macOS 27 warned that the current `hdiutil create` syntax
is deprecated. Those did not fail the builds or package checks. No tooling refactor was made.

### Sparkle and package details

The production `SUFeedURL` remains
`https://raw.githubusercontent.com/jewei/claude-meter/main/appcast.xml`.
The embedded public key is unchanged from 2.18. Build 295 is greater than 292.
The current configuration uses HTTPS feed delivery and Ed25519 archive verification;
`SURequireSignedFeed` is not enabled. No signing key was rotated or exported.
The private staging check downloaded the candidate through loopback HTTP, compared
its hash, and verified its archive signature. It did not exercise Sparkle installation.

The package contains the app, intended resources and Sparkle components. It contains
no widget, test fixtures, profiler/sampler, DerivedData, local configuration, legacy
artifacts or private signing material. The binary's two home-path pattern matches are
sanitizer rules/placeholders, not an actual private home. Debug symbols match the app.

### Final commands

All commands below passed after the code fixes:

```sh
swift test --package-path ClaudeMeterCore
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO
./scripts/verify-local.sh
git diff --check
./scripts/release.sh 3.0 295 --prepare-only
```

`verify-local.sh` also passed four release-publication/signing-order tests and 13
optional upgrade-helper fixtures. Final artifact checks included recursive strict
`codesign` verification, both `notarytool` logs, `stapler validate`, app and DMG
`spctl` assessments, mounted-DMG checks, symbol checks and Sparkle signature verification.

**Recommendation: candidate is blocked** until the isolated clean-install and actual
2.18-to-3.0 upgrade tests can run. Physical sleep/wake, older macOS/Intel execution and
live multi-account/recovery cases remain documented gaps. Keep the candidate private.
Do not start another architecture or performance phase.

## Phase 12A: upgrade artifact cleanup

The Phase 11 inventory was checked against the deleted implementations in Git and
current readers. The existing statusline suite passed before changes, including
flat/per-account captures, temporary files, user commands, and links. No second
statusline or attention cleanup was added.

### Startup order and dependencies

1. Keep existing settings repair and onboarding behavior.
2. Attempt `LegacyAttentionHookMigration` off-main.
3. Attempt `LegacyStatuslineMigration` off-main.
4. Request the App Group snapshot import through `ClaudeReadingStore`'s existing
   serial queue, even if Claude is disabled.
5. Run `LegacyArtifactCleanupMigration`. It requires all three earlier completion
   flags before it deletes any file.
6. Set `didCleanupObsoleteArtifacts.v1` only after each of its seven files is removed
   or proven absent. Failure leaves this new key unset for a later launch.

The earlier three key names and semantics are unchanged. Each startup attempt has its
own error handling, so failure does not prevent normal application startup. Provider
restoration can also request the existing import on the same queue. Only final cleanup
depends on all three flags; hook/statusline cleanup does not consume snapshot data.

The App Group `current.json` is safe to remove only after
`didImportLegacyAppGroupSnapshot.v1` is true. That means the bounded import either
saved the newer legacy observation, kept an equally new/newer current observation,
or found no legacy input. Decode, read, or write failure leaves the flag unset and
preserves the source. A separate importer was not added, because it could race a
current accepted write. The new startup entry uses the existing storage queue and
returns immediately when the import key is already complete.

### Final artifact matrix

Paths are relative to the user's home. These aliases name exact directories:

- `A`: `Library/Application Support/ClaudeMeter`
- `P`: `Library/Caches/com.jewei.claudemeter`
- `G`: `Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter`
- `R`: `.claude-meter`

| Exact file or bounded historical scope | Historical owner | Current read / compatibility use | Cleanup owner and condition |
| --- | --- | --- | --- |
| `A/cost-usage-cache.json` | CostUsageCache | None | New cleanup after prerequisites; no decoding |
| `P/models-dev-pricing-v1.json` | ModelsDevPricing | None | New cleanup after prerequisites; no decoding |
| `G/main-meter.json` | MainMeterPublication / widget | None; no extension is shipped by the current target | New cleanup after prerequisites |
| `A/main-meter.json` | Widget publication when App Group creation failed | None | New cleanup; the old `AppState.makeStore()` proves this exact fallback path |
| `G/current.json` | App Group SnapshotStore | Import input only | New cleanup only after successful import completion flag |
| `G/last-error.json` | Old shared diagnostics | None; import does not use it | New cleanup after prerequisites |
| `A/usage-history.jsonl` | Deleted usage history | No reader | Existing deletion moved into new versioned cleanup; no duplicate task |
| `R/sessions/*`, `R/sessions/<account>/*`, `R/statusline.json`, numeric `R/.sl-*` | StatuslineBridge captures | Existing cleanup migration only | LegacyStatuslineMigration, after config cleanup; unchanged |
| `R/events/*`, `R/events/<account>/*` | HookBridge events | Existing cleanup migration only | LegacyAttentionHookMigration makes its existing safe best-effort attempt; unchanged |
| `Library/Group Containers/group.com.jewei.claudemeter/Library/Preferences/group.com.jewei.claudemeter.plist` | App Group display defaults | No current app/import consumer | Retained; an independently installed older widget/app and preferences service can still hold settings |
| `Library/Preferences/group.com.jewei.claudemeter.plist` | Legacy suite defaults | No current app/import consumer | Retained for the same reason; no blind domain/file removal |
| Temporary directory `current.json`, `main-meter.json`, `last-error.json` | Old emergency store if both normal factories failed | No current reader; files at these generic names have no reliable ownership stamp | Retained; cannot establish exclusive app ownership, no temporary-directory scan |

Current Application Support `current.json` and `last-error.json`, Codex last-good
defaults, credentials, user Claude settings, and unknown neighboring files are never
targets. Only the shared container's snapshot/error copies are obsolete. Git confirms
that old settings were mirrored to standard defaults; no new settings import is needed.
The current project contains an app and its test target, with no widget product or
embedding. Local verification also checks that the built app contains no extension.
That does not prove that an independently installed older consumer has gone away, so
the two small shared-defaults files are retained. Empty containers/directories and
unknown entries remain. Inaccessible attention files retain the existing best-effort
contract; this phase does not bypass or reset that migration's completion key.

**Coverage:** five artifact classes gain cleanup for the first time. Usage history is
one existing class transferred to the protected cleanup. Widget publication has two
proven locations, for seven exact files in total. Two classes are intentionally retained:
shared defaults at two paths, and ambiguous generic emergency-store files in temporary
storage. The latter came from the historical `makeStore()` fallback and were not part
of the Phase 11 observed files. Capture and event files keep their existing owners.

### Filesystem and retry rules

The new migration starts at an open home directory and traverses fixed components
with no-follow descriptors. It checks parent identity even when a missing component
proves absence. It removes only an unchanged regular final entry. It does not read
cache contents, follow directory/file links, create legacy storage, delete directories,
or enumerate arbitrary contents. Unexpected paths, permission failures, and changed
entries prevent completion. Independent files can still be removed during a partial
failure, and the next launch can finish. A completed cleanup reads its defaults key
and returns without filesystem work.

Tests use isolated temporary homes and UserDefaults suites. The public startup cleanup
and new import-preparation entry reject live-home work in hosted tests. No installed
user artifacts were deleted to verify this phase.

### Compatibility code retained

| Path or behavior | Classification | Reason it remains |
| --- | --- | --- |
| Attention/statusline migrations and their original completion keys | Required for supported direct upgrades | Older released installs still contain owned hooks/snippets; user commands must survive |
| App Group snapshot import and original completion key | Required for supported direct upgrades | An older shared observation can be the only or newest last-good data |
| New final cleanup and usage-history path | Required for supported direct upgrades | Older installs still contain derived data; failed deletion must retry |
| Old statusline snapshot detection and old date/field decoding | Removal candidate only after a future minimum-version cutoff | Direct upgrades must decode old snapshots safely and mark statusline observations stale |
| SettingsFile / LegacyClaudeFiles migration utilities | Removal candidate only after a future minimum-version cutoff | They protect exact snippet repair and captured-file cleanup for those upgrades |
| Claude snapshot shape, top-level compatibility fields and account arrays | Current-format compatibility | The provider still writes this format; no disk schema change in this phase |
| Codex schema 2, owner validation, rejection of ownerless schema 1 | Current-format compatibility | An old archive must never transfer usage to another owner |
| Menu-bar selection repair, stable account-pin keys, threshold repair and 600 s stale minimum | Required for supported direct upgrades and current input validation | Old preferences remain valid without changing selection policy |
| OAuth legacy/hashed Keychain lookup and per-config-dir credential discovery | Current upstream credential compatibility | Current provider versions and user configurations can still use these forms |
| Grok OIDC/legacy credential lookup, Cursor supported token encodings, ProviderDate fallbacks | Current upstream format compatibility | These are supported inputs, not files owned by deleted app features |
| Shared-defaults files | Removal candidate only after a separate old-consumer review | Current code does not need them, but a different installed app/widget can still do so |

No earlier key is deleted, renamed, reset, or folded into the new key. No minimum
supported upgrade version is introduced. UsageStore, RefreshScheduler, fetching,
authentication, UI, cadence, and current persistence formats remain unchanged.

### Tests and size

The 13 focused cleanup tests cover exact deletion, malformed cache bytes, absence,
idempotence with/without the completion flag, each missing prerequisite, filesystem
and permission failures with retry, parent/final links, FIFOs, failed import reads and
writes, newer destination data, successful import followed by cleanup, the existing
hook/statusline sequence, settings/neighbor preservation, and storage-queue ordering.
All use isolated storage and defaults. No signed-release validation is part of Phase 12A.

| Swift code | Before | After | Change |
| --- | ---: | ---: | ---: |
| Production files | 71 | 72 | +1 |
| Production LOC | 17,070 | 17,178 | +108 |
| Test files | 41 | 42 | +1 |
| Test LOC | 12,010 | 12,352 | +342 |

Counts include the app, package Sources, app tests, and package Tests. They exclude
manifests, generated files, and dependencies. The new cleanup is 93 LOC. The existing
usage-history task was removed from AppState; its file remains covered by the new owner.

### Phase 12A verification

| Command | Result |
| --- | --- |
| `swift test --package-path ClaudeMeterCore --filter LegacyStatuslineMigrationTests` before changes | Passed: 9 tests, including representative capture cleanup |
| `swift test --package-path ClaudeMeterCore` | Passed: 101 Core tests and 334 provider tests |
| `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO` | Build succeeded |
| `./scripts/verify-local.sh` | Passed: formatting, script fixtures, package tests, 88 app tests, Debug/Release builds, and no app extension |
| `git diff --check` | Passed |

Source searches for the exact artifact names, shared defaults, and deleted cache/widget
types found only the final cleanup and the existing App Group snapshot import in
production. Hook/statusline type names remain only as historical migration references.
Current Application Support snapshot/error readers remain intact. Existing accessibility
deprecation warnings are unchanged. No signed app or release upgrade was validated.

## Phase 11: runtime baseline, 2026-09-23

This phase changes no production code. It adds the development sampler
`scripts/measure-runtime.c` and this report. Raw traces, logs, and build products are
outside the repository. No obsolete user files were removed.

### Environment and limits

- MacBook Air, Mac14,2, arm64, 8 CPU cores, 16 GiB RAM.
- macOS 27.0, build 26A428. This is one development machine, not a hardware survey.
- Release, normal ClaudeMeter target, `CODE_SIGNING_ALLOWED=NO`. The local executable
  has a linker ad-hoc signature; this is not a distribution-signed release test.
- Git base: `2bf67b2c6a7810267306e85201e710e63dfbc37f`. Phases 1–10 are local
  working-tree changes. The project Swift source/test tree SHA-256 was
  `9eaef4ecbc397de438dffe82ed27b0521fc5c453335f4be7c70622fd79a6caf3`.
  This hashes sorted records of relative path, NUL, file SHA-256, and newline. It
  excludes build products and dependencies. All 114 project Swift files are unchanged.
- Codex: enabled, one home, healthy direct OAuth. Cursor: enabled and healthy.
  Grok: enabled but unavailable before HTTP. Claude: disabled. Existing provider
  choices and credentials were not changed. No auth recovery was forced.
- Onboarding complete, active, Codex selected, display awake, popover closed except
  during the specified scenarios. Sparkle settings were unchanged.
- The installed older app was stopped during measurement. Its separately hosted old
  widget remained a host-system confounder, not a child of the measured process.
- To keep the artifact inventory non-destructive, launch arguments set the three
  migration completion flags for this process only. Persistent flags were not set.
  Migration execution cost is therefore **not measured**. Legacy usage history was
  absent. Do not use these arguments for a normal upgrade.

### Method and reproduction

```sh
xcodebuild -scheme ClaudeMeter -configuration Release \
  -derivedDataPath /tmp/claude-meter-phase11/DerivedData CODE_SIGNING_ALLOWED=NO
clang -O2 -Wall -Wextra -Werror scripts/measure-runtime.c -o /tmp/measure-runtime
open -n /tmp/claude-meter-phase11/DerivedData/Build/Products/Release/ClaudeMeter.app \
  --args -didRemoveLegacyAttentionHooks.v1 YES \
  -didRemoveLegacyStatuslineBridge.v1 YES -didImportLegacyAppGroupSnapshot.v1 YES
# Obtain the new app PID. Keep all following output outside the repository.
/tmp/measure-runtime PID 4500 > /tmp/resources.csv
```

Stop another running copy first. Use a private output directory. Record enabled
provider counts, build identity, launch time, and UI event times without account data.
For the clean run, leave the app alone through the first scheduled refresh. Then open
within 60 seconds of success, leave the popover visible for a minute, close it, and
open again after the observations are at least 60 seconds old. Close it for the next
background cycle. Do not run builds during these samples.

The sampler reads `proc_pid_rusage` every 200 ms. CPU is the change in user plus system
CPU time divided by elapsed time; 100% means one core. Mach ticks are converted with
`mach_timebase_info` (125/3 on this machine). RSS and physical footprint are different
metrics. Wakeup figures below are kernel interrupt-wakeup counter deltas, not counts
of Swift timer callbacks. Child sampling can miss a process shorter than 200 ms.

Additional tools: process-filtered `nettop`, CFNetwork unified-log request summaries,
`sample`, Instruments Time Profiler through `xctrace`, and `leaks --noContent`.
Only request counts/status/duration were extracted into this report. Raw logs and
traces can contain private data and must not be committed. CPU sampling and tracing
can affect the target; the main idle and background rows had no profiler attached.

### Runtime results

The table uses the clean Launch Services run. CPU is a window average, not a single
Activity Monitor reading. MiB uses 1,048,576 bytes. Request counts are observed HTTP
requests, not scheduler calls. Child counts are observed direct children.

| Scenario | Sample | CPU, one core | RSS, MiB | Interrupt wakeups/s | HTTP requests | Children |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| A: closed settled idle | 89.7 s | 0.002% | 68.3–80.8 | 0.11 | 0 | 0 |
| A: closed idle repeat | 129.9 s | 0.010% | 69.7–72.5 | 0.32 | 0 | 0 |
| B: scheduled refresh | 4.9 s | 2.28% | 70.7–79.8 | 3.88 | 2 | 0 |
| B: second scheduled refresh | 4.9 s | 2.19% | 61.7–63.1 | 3.48 | 2 | 0 |
| C: first fresh popover open | 4.9 s | 3.65% | 82.8–102.5 | 4.29 | 0 | 0 |
| D: old popover open and refresh | 4.7 s | 2.93% | 65.5–66.3 | 9.37 | 2 | 0 |
| E: visible countdown, settled | 59.8 s | 1.15% | 86.4–101.8 | 2.23 | 0 | 0 |
| Closed after UI and refresh | 99.9 s | 0.007% | 61.9–62.4 | 0.39 | 0 | 0 |
| F: display sleep/wake | runtime n/a | n/a | n/a | n/a | n/a | n/a |

Scenario D had Time Profiler attached; its CPU/wakeup cost includes that effect.
Scenario C includes first-use SwiftUI/font/layout work. In the earlier run, reopening
an already constructed fresh popover averaged 0.34% over 4.7 seconds. The earlier
visible samples were 0.48–0.90%; the one-minute clean sample is the primary result.
Grok was still failed, so a fresh open could retry local credential discovery. The
zero-request result proves no HTTP work for the two healthy providers; it does not
prove that every enabled provider skipped its local work.

The background refresh consumed 0.112 CPU-seconds. Its highest 200 ms CPU sample was
27% of one core. The two HTTP transactions completed in 793 and 838 ms, both HTTP 200.
The first scheduled sends occurred about 320 seconds after launch, against a nominal
300-second timer. The cause of this delay was not isolated. Do not treat the timer as
a real-time deadline. The second scheduled cycle started at 640 seconds and used
0.107 CPU-seconds. An earlier run with UI automation did not isolate the scheduled
cycle reliably; the clean run is the basis for this result.

Launch used 0.232 CPU-seconds in the first measured 4.9 seconds, averaging 4.73%.
The sampler attached shortly after process creation, so it does not include all dyld
work. Initial HTTP work completed by 1.24 seconds after launch. RSS peaked near
89.4 MiB in this window, then settled. About 17 MiB of process disk reads were counted
by five seconds in the clean warm launch. This is not a cold-cache launch benchmark.
Discovery, framework loading, and initial fetch were not separately timed.

### Memory and MainActor

Closed-idle physical footprint was about 19.1 MiB. The first popover raised it to
30.3 MiB; a later refresh/open was about 31.1 MiB. After closing the popover and the
second background refresh, it returned to 31.0 MiB, with RSS at 62.3–62.9 MiB.
The earlier run reached about
35.1 MiB after more UI/profiler activity. RSS fell as pages left residency, so RSS
changes alone do not show allocation growth. These short runs show a first-use UI
allocation increase, not continuing provider-result accumulation.

Two separate `leaks --noContent` scans each reported **416 objects / 19,936 bytes**,
with framework/NSXPCConnection cycles in the output. No allocation-history trace
established an app call site. Treat this as a small unresolved tool finding, not a
proved ProviderSnapshot, Task, SQLite-handle, HTTP-buffer, or Codex-client leak.
No long-duration retention claim is possible from these runs.

Time Profiler sampled SQLite, Codex credential reads, and JSON decoding on worker
threads. No meaningful MainActor stall was found. Two traces had 1–2 ms of sampled
`lstat` work on MainActor through `AppState.codexAccounts` → `AppSettings.codexAccounts`
→ Foundation URL path handling. These are sampled totals, not individual call
durations. This settings lookup is also present in the visible UI call tree. It is a
minor synchronous filesystem path to retain in the risk inventory; no costly disk
stall was measured. Claude Keychain and snapshot writes were not exercised.
The captured hang and hang-risk tables contained no events.

### Timers, network, and processes

The source has one 300-second scheduler sleep and a one-second popover task gated by
visibility. The clean closed interval had no one-minute HTTP activity. The visible
countdown had no HTTP requests. After close, CPU and wakeups returned to the idle
range. No separate reconnect or battery timer exists.

Actual display sleep was not forced on the user's machine. `RefreshSchedulerTests`
cover parking, no late timer work, fresh/old wake behavior, and resume with an injected
clock. Runtime sleep/wake confirmation remains n/a.

Each observed successful cycle had two requests. This matches one Codex quota request
and one Cursor usage request in the configured healthy paths. The old-reading
interactive cycle completed them in 297 and 590 ms. Individual transaction durations
were not attributed to an endpoint. The clean run had eight HTTP 200 responses across
launch, two background cycles, and one old-reading open.
Provider CPU attribution was too sparse for a reliable per-provider CPU table.
No Grok HTTP request, Claude request, or auth-refresh request was observed.

| Provider | Global background budget while awake | Normal HTTP budget, excluding auth recovery |
| --- | --- | --- |
| Claude | 12 invocations/hour | Up to 12 usage GETs/account/hour before internal reuse/backoff; secondary accounts retain their 300 s policy |
| Codex | 12 invocations/hour | 12 direct quota GETs/home/hour with healthy credentials |
| Cursor | 12 invocations/hour | 12 usage POSTs/hour; up to 12 more plan POSTs if membership is absent |
| Grok | 12 invocations/hour | 12 billing GETs/hour; up to 24 attempts with its one transient retry; unavailable local credentials make 0 |

These are calculations, not hourly request measurements. Launch, settings, manual
refresh, and old popover/wake events add opportunities. Token refresh and recovery add
requests; OAuth 429 gates can reduce them. There is no fixed request maximum that
includes arbitrary user actions. Sparkle is separate from the provider budget.

No Codex, sqlite3, or other app child was observed in either run. Source inspection
confirms that healthy Codex has no process launch and Cursor has no process path.
The macOS provider process site is one-shot Codex recovery. It did not run in this
configuration. `OAuthKeychain.runSecurity` still contains a process helper, but its
callers are under `#else` for `canImport(Security)`. This macOS build uses the Security
framework and cannot call that fallback. Recovery was not forced. The installed old
widget is not part of this build.

### Obsolete artifact inventory, no deletion

Paths below are canonical patterns, not this user's full paths. Sizes are logical
file bytes, not allocated disk blocks. Where only an observed size is listed, no
historical size cap was established; that value is not a maximum. `G` means
`~/Library/Group Containers/group.com.jewei.claudemeter`.

| Pattern | Former owner; current reader | Observed size; possible size | Cleanup confidence / migration coverage |
| --- | --- | --- | --- |
| `~/Library/Application Support/ClaudeMeter/cost-usage-cache.json` | CostUsageCache; none | 23,681 B; old disk cap 64 MiB | High: derived app data; no cleanup migration |
| `~/Library/Caches/com.jewei.claudemeter/models-dev-pricing-v1.json` | ModelsDevPricing; none | 1,208 B; old read cap 32 MiB, no explicit write cap | High: derived prices; no cleanup migration |
| `G/Library/Application Support/ClaudeMeter/main-meter.json` | Widget publication; none in current build | 546 B here | High after the older widget/app is retired; no cleanup migration |
| `G/Library/Application Support/ClaudeMeter/current.json` | Legacy SnapshotStore; import migration only | 1,243 B; current reader cap 4 MiB | Retain until successful import; migration leaves source file |
| `G/Library/Application Support/ClaudeMeter/last-error.json` | Legacy diagnostics; none | Absent here | High once old app is retired; no cleanup migration |
| `G/Library/Preferences/group.com.jewei.claudemeter.plist` | Shared defaults; none in current build | 712 B here | Preserve until old consumer is retired; settings already mirrored to standard defaults |
| `~/Library/Preferences/group.com.jewei.claudemeter.plist` | Legacy suite defaults; none in current build | 685 B here | Same restriction; no cleanup migration needed for current settings |
| `~/.claude-meter/sessions/**`, `statusline.json`, `.sl-<digits>` | Captured statusline data; cleanup migration only | 36 session files, 40,496 B here; no aggregate old cap | Exact managed patterns only; LegacyStatuslineMigration handles safe removal |
| `~/.claude-meter/events/**` | Attention hook events; cleanup migration only | None here; historical accumulation had no aggregate cap | LegacyAttentionHookMigration removes verified app files |
| `~/Library/Application Support/ClaudeMeter/usage-history.jsonl` | Old usage history; startup deletion only | Absent here | Existing unversioned startup cleanup |

Activity and Codex cost caches were memory-only; no separate disk artifact was found
in the deleted implementation. Do not delete the whole App Group or `.claude-meter`
directory. Old installed consumers and migration inputs require separate checks.
The measured leftovers are small. This inventory does not justify a new permanent
cleanup subsystem.

### Migration inventory

- `LegacyAttentionHookMigration`: `didRemoveLegacyAttentionHooks.v1`. Removes exact
  owned hook entries and event files; completion requires safe coverage of managed dirs.
- `LegacyStatuslineMigration`: `didRemoveLegacyStatuslineBridge.v1`. Removes known
  bridge snippets and captured files, preserves user commands and `refreshInterval`.
- `SnapshotStore.importLegacyAppGroupSnapshotIfNeeded`:
  `didImportLegacyAppGroupSnapshot.v1`. Imports a newer compatible observation and
  leaves the source. Completion follows a successful attempt.
- `AppState.removeLegacyUsageHistory`: no completion key; checks the old file at launch.
- `MeterSettings.repairMenuBarWindow`: obsolete/invalid selection becomes `nearest`.
  `repairThresholdSettings` repairs ranges. Neither uses a version flag.
- `resolvedStaleAfterSeconds` applies the 600 s minimum to old settings without a
  migration write. Codex archive schema 2 (`codexLastGoodReadings.v1`) rejects ownerless
  schema 1. OAuth Keychain legacy/hashed lookup is read compatibility, not a migration.

No migration was removed or consolidated. The three versioned flags were absent from
the installed defaults before this run; process arguments skipped them only for profiling.

### Findings and next decision

| Class | Evidence | Decision |
| --- | --- | --- |
| Material | No material runtime cost was established in the tested configuration | No architecture optimization is justified |
| Minor | Visible countdown averages 1.15% of one core; first view open adds about 11 MiB footprint | Keep behavior; do not rewrite SwiftUI or reduce timer frequency from this sample |
| Minor | Refresh uses 0.112 CPU-seconds; requests take less than one second | Keep provider paths; request waiting is not continuous CPU work |
| Minor | MainActor URL lookup has 1–2 ms sampled filesystem work; 19.5 KiB unresolved leak report | Retain as bounded follow-up evidence, not a measured blocking/leak diagnosis |
| Negligible | Closed idle uses 0.002–0.010% CPU with 0.11–0.32 interrupt wakeups/s | No idle optimization target |
| Not measured | Claude, successful Grok, auth recovery, migration execution, actual sleep, long-term retention | Do not generalize the two healthy-provider result to these paths |

**Primary next action: final cleanup and release hardening.** Stop major performance
refactors. Validate the signed release with the unmeasured provider/upgrade paths and
use the artifact inventory for a separate cleanup decision. No next phase is
implemented here.

### Verification

| Command | Result |
| --- | --- |
| `swift test --package-path ClaudeMeterCore` | Passed: 101 Core tests and 321 provider tests |
| `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO` | Build succeeded |
| `./scripts/verify-local.sh` | Passed: release-script checks, formatting, package tests, 88 app tests, Debug and Release builds, and no app extension |
| `git diff --check` | Passed |
| `clang -O2 -Wall -Wextra -Werror scripts/measure-runtime.c -o /tmp/measure-runtime` | Passed; sampler also ran against the measured app |

The Release measurement build also succeeded. Xcode reported duplicate matching Mac
destinations and selected arm64; no check failed. The installed app was restored after
measurement. No production Swift file changed in Phase 11.

## Objective

Revamp Claude Meter into a small, resource-efficient macOS menu-bar utility focused on one job:

> Show current usage/balance and reset countdowns for Claude, Codex, Cursor, and Grok.

The existing repository has accumulated substantial complexity from features that are no longer part of the desired product. Do not merely reorganize that complexity. Remove obsolete requirements first, then rebuild the remaining architecture around a small normalized provider model.

The priority order is:

1. Delete obsolete functionality.
2. Reduce background work.
3. Normalize provider interfaces.
4. Replace the god-object state architecture.
5. Simplify providers.
6. Simplify presentation.
7. Measure CPU/RAM/network impact.
8. Only then consider UI-framework changes.

Do **not** rewrite the application in Rust. Keep Swift 6 and native macOS APIs.

---

# 1. Target Product Scope

The finished application should support:

* Claude usage windows
* Codex usage windows / balance where available
* Cursor usage
* Grok usage / balance
* reset timestamps and countdowns
* stale/error state
* manual refresh
* automatic low-frequency refresh
* provider enable/disable
* basic account/plan information where already available
* launch at login if currently supported and inexpensive
* application updates if Sparkle remains useful

Everything else requires explicit justification.

## Remove from scope

Remove:

* native notifications
* predictive notifications
* quota threshold notifications
* attention notifications
* Claude Code Stop/StopFailure hooks used for notifications
* terminal focusing from notification actions
* local historical analytics, removed in Phase 2
* Anthropic service-status polling (removed in Phase 3)
* usage depletion forecasting (removed in Phase 3)

Do not leave dormant implementations behind "for later."

Delete dead code, tests, settings, persisted keys, documentation, and UI associated with deleted functionality.

---

# 2. Non-goals

Do not add:

* Rust
* Tauri
* Electron
* a database owned by Claude Meter unless clearly necessary
* generic plugin systems
* dependency-injection frameworks
* event buses
* service locators
* elaborate provider registries
* protocol abstractions without an actual current use
* caching layers solely to compensate for unnecessarily frequent polling
* background daemons
* hidden WebViews
* provider subprocesses when direct local/API access is sufficient

Prefer boring code.

---

# 3. Architecture Principle

The app should conceptually be:

```text
macOS UI
   │
   ▼
UsageViewModel
   │
   ▼
UsageStore
   │
   ├── ClaudeProvider
   ├── CodexProvider
   ├── CursorProvider
   └── GrokProvider
```

Provider-specific details must terminate at the provider boundary.

The UI should not know:

* where provider credentials are stored
* whether the provider uses Keychain or a file
* which HTTP endpoint was used
* whether SQLite was needed
* how the provider names its quota windows
* how token refresh works

The scheduler should not know any of those things either.

---

# 4. Shared domain model completed in Phase 6

Core's [ProviderSnapshot.swift](ClaudeMeterCore/Sources/ClaudeMeterCore/ProviderSnapshot.swift)
defines the implemented model:

```text
ProviderSnapshot: provider, accounts[], fetchedAt
ProviderAccountSnapshot: id, label, plan, subtitle, windows[], balances[], observedAt, isStale
UsageWindow: id, title, kind, usedPercent, resetAt, contributesToQuota, isOverLimit
BalanceItem: id, title, value, limit, unit, displayText, details[]
BalanceDetail: title, expiresAt
```

`ProviderID` names the four supported providers. Percentages mean used and stay in
0...100; unknown stays nil. Account arrays preserve Claude and Codex multi-account data
without a duplicate selected account. Selection remains application policy.

Each provider has a local adapter. `AppState.normalizedSnapshots` computes a view of
UsageStore with display overrides. All cards use normalized values. Both existing
persistence formats stay inside Providers. SPECS.md records mapping and identity rules.

---

# 5. Provider fetch contract

All four adapters use the same Core fetch contract.
SPECS.md records the explicit reconciliation, fetch and commit sequence. The provider
boundary is:

```swift
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var ownsDeadline: Bool { get }

    @MainActor func validatePrevious(
        _ previous: ProviderSnapshot?, now: Date, refreshID: UUID
    ) async throws -> ProviderSnapshot?

    func fetch(
        now: Date, previous: ProviderSnapshot?, refreshID: UUID
    ) async throws -> ProviderSnapshot

    @MainActor func didAccept(_ snapshot: ProviderSnapshot, refreshID: UUID)
    func waitForPersistence() async
}
```

Codex captures homes through its configuration supplier. UsageStore does not interpret home paths.

Do not expose:

```swift
ClaudeUsageSnapshot
CodexUsage
CursorUsage
GrokUsage
```

to application UI/state code after the migration.

Those may remain private provider-layer types if they are still useful for decoding.

---

# 6. Preserve the Good Existing State Model

The existing `ReadingState` concept is useful:

```swift
enum ReadingState<Value: Sendable>: Sendable {
    case current(value: Value, polledAt: Date)
    case stale(value: Value, polledAt: Date, error: String)
    case failed(error: String, lastPolledAt: Date?)
}
```

All four providers use this Core reading state through UsageStore.

Desired semantics:

* successful refresh → `.current`
* transient failure with previous value → `.stale`
* failure without previous value → `.failed`
* disabled provider → no reading

Do not invent separate lifecycle models for individual providers unless required by correctness.

---

# 7. Replace `AppState` with Smaller Responsibilities

Current `AppState.swift` has become a god object.

It should not own:

* provider implementation logic
* provider credential handling
* subprocess lifecycle
* notification state
* hook reconciliation
* service-status polling
* networking policy

Target structure:

```text
AppState / UsageViewModel
    UI-facing observable state only

UsageStore
    provider readings
    refresh orchestration
    last-good handling

RefreshScheduler
    automatic refresh timing
    wake/reconnect behavior if retained

Provider implementations
    authentication
    provider HTTP/local data
    provider decoding
```

Aim for `AppState`/`UsageViewModel` to become hundreds of lines rather than thousands.

Do not split the existing god object into ten classes that still depend tightly on one another. First reduce responsibilities.

---

# 8. UsageStore migration completed

`@MainActor UsageStore` owns all provider readings, refresh tasks and loading state.
Provider I/O runs off-main through the existing timeout helper. Observable state reaches
views through AppState's forwarded change notification; there is no mirrored dictionary.

RefreshScheduler owns global scheduling and admission. Persistence
formats remain unchanged. The store has no disk cache. See SPECS.md for cancellation,
failure and freshness rules.

---

# 9. Refresh Strategy

Implemented in Phase 8:

```text
background refresh: 300 seconds for every enabled provider
popover opened: missing/failed/stale or at least 60 seconds old
manual refresh: immediate, independent of age
wake: refresh if missing/failed/stale or at least 300 seconds old
sleep: timer parked, no provider work
UI age staleness: 600 seconds by default and minimum
```

Network reconnect and battery state do not change scheduling.

Do not fetch every second.

Do not fetch every minute without demonstrated need.

Reset countdowns are computed locally from:

```swift
resetAt.timeIntervalSince(now)
```

No network request is necessary to update a countdown.

While the popover is visible:

* update countdown presentation locally
* a one-second UI timer is acceptable if seconds are displayed

While hidden:

* stop the one-second timer
* do not keep animations/display links running

---

# 10. Claude source decision completed

Phase 5 made Claude usage OAuth-only. Future provider work must preserve token refresh,
Keychain safety, provider backoff, account identity, and stale last-good data. Do not
restore a statusline source. Provider normalization remains separate work.

---

# 11. Codex provider

Completed in Phase 9. Direct OAuth is the normal path for each configured home.
Only typed credential/auth failures use one bounded App Server recovery fetch. Codex owns
refresh-token rotation and auth storage. Claude Meter never writes Codex credentials.

The source picker and process pool are removed. All recovery outcomes await shutdown.
Ownership validation, unknown-owner restrictions, last-good persistence, quota windows,
balances and multi-home concurrency remain. Direct usage includes reset-credit totals;
detailed expiry rows require a recovery response and are not fetched separately.

---

# 12. Cursor provider

Credentials use system SQLite directly with read-only flags and `readonly_shm=1`.
One bound SELECT reads the four authentication keys, then closes the connection.
SQLite handles live WAL data. Missing required sidecars fail without repair.
The subprocess, DB/WAL/SHM identity cache and header inspection are removed.
Keychain fallback and memory-only token refresh remain. No Cursor database writes occur.

---

# 13. Grok Provider

Grok is already close to the desired provider architecture.

Keep its shape approximately:

```text
read ~/.grok/auth.json
        ↓
authenticated HTTP request
        ↓
decode
        ↓
ProviderSnapshot
```

Do not add additional source fallbacks unless required.

Use Grok as a reference for how small a provider adapter should feel from the application layer.

---

# 14. Delete Notifications Completely

Delete the feature rather than hiding its UI.

Likely deletion candidates include:

```text
ClaudeMeter/NotificationEngine.swift
ClaudeMeter/NotificationsSettingsTab.swift
ClaudeMeterCore/.../NotificationPolicy.swift
ClaudeMeterCore/.../PredictiveNotificationPolicy.swift
ClaudeMeterCore/.../HookBridge.swift
ClaudeMeterCore/.../SessionEvent.swift
```

Then remove associated:

* settings keys
* notification baselines
* deduplication state
* alert identities
* predictive state
* Notification Center authorization
* attention marker watcher
* two-second attention polling
* hook installation/reconciliation
* attention self-healing
* tests
* specifications
* diagnostics
* UI notices

Evaluate `TerminalFocusRouter.swift` after removing notification actions.

If nothing else uses it, delete it.

---

# 15. Local analytics removal completed

Phase 2 removed the analytics window, scanners, pricing, caches, and their system
monitor. Live provider balances remain. Statusline removal was completed in Phase 5.

---

# 16. Service Status Removal — Complete

Phase 3 removed service-status polling and incident banners. Provider fetch results
continue to determine current, stale, and failed presentation.

---

# 17. UI Simplification

The UI should render normalized provider snapshots instead of branching deeply by provider.

Target concept:

```swift
ForEach(enabledProviders) { provider in
    ProviderCard(
        reading: readings[provider.id]
    )
}
```

A provider card should generically display:

```text
Provider
Plan/account

5-hour        42% used
resets in 2h 14m

Weekly        61% used
resets in 3d 8h

Balance       ...
```

Provider-specific additions should be exceptional.

Avoid separate giant code paths such as:

```text
claudeProviderSection
codexProviderSection
cursorCard
grokCard
```

where the distinction is primarily presentation.

---

# 18. Popover

`PopoverView.swift` is currently too responsible.

Split presentation by semantic component, not arbitrary file size:

```text
PopoverView
ProviderList
ProviderCard
UsageWindowRow
ResetCountdown
EmptyState
ErrorState
```

Do not recreate a large "Components.swift" dumping ground.

Simple components can remain in the same file until reuse justifies extraction.

---

# 19. SwiftUI vs AppKit

Do not change the UI framework during the first architecture migration.

Keep the existing SwiftUI popover until provider/state architecture is stable.

After the revamp, benchmark the app.

Only if SwiftUI/MenuBarExtra materially contributes to idle CPU/RAM should the lifecycle move to:

```text
NSStatusItem
NSPopover
NSHostingController<PopoverView>
```

This gives AppKit explicit lifecycle control while retaining SwiftUI for the actual content.

Do not rewrite the popover as a large imperative AppKit UI unless measurements justify it.

---

# 20. Widget Removal Complete

Phase 4 removed the desktop extension, publication files, revisions, and App Group
mirroring. Standard defaults remain authoritative. Claude snapshots use Application
Support with a one-time import from the old group container.

---

# 21. Persistence

Persist only information that improves startup/offline behavior.

Prefer:

```text
last-good ProviderSnapshot per provider/account
```

Do not persist transient refresh errors unless diagnostics genuinely require it.

Do not duplicate provider state between several files and UserDefaults.

Persisted data must be versioned if migration is necessary.

The App Group was removed in Phase 4. Retained provider persistence remains a later decision.

---

# 22. Settings

Collapse Settings toward:

## Providers

```text
Claude       enabled
Codex        enabled
Cursor       enabled
Grok         enabled
```

plus only authentication/account controls that are actually necessary.

## Appearance

Keep only visible choices users meaningfully use.

## General

Potentially:

```text
Launch at login
Refresh interval
Check for updates
```

Remove:

* Notifications tab
* notification thresholds
* predictive settings
* attention settings
* source options for source implementations that no longer exist
* advanced switches added solely to support obsolete architecture

An "Advanced" tab should not become a graveyard for old internal complexity.

---

# 23. Forecast Removal — Complete

Phase 3 removed usage pace, depletion predictions, and the menu-bar forecast option.
Existing forecast selections normalize to nearest. Provider reset countdowns and
`ResetPhrase` remain.

---

# 24. Simplify `Models.swift`

Current Core models contain fields for historical features.

Phase 5 removed local session fields. Audit the remaining fields during provider normalization.

Delete fields not required for:

* provider identity
* account identity
* plan
* usage percentage
* reset time
* balance
* stale/fresh/error state

Do not retain fields solely for old snapshot compatibility unless existing releases require a migration.

If migration is required, perform it at the persistence boundary and keep the new in-memory model clean.

---

# 25. Testing Strategy

Do not preserve tests for deleted features.

Delete tests together with deleted production behavior.

Replace the giant app-level test file with focused suites.

Suggested structure:

```text
Tests/
    UsageStoreTests
    RefreshSchedulerTests
    ProviderSnapshotTests

ProviderTests/
    ClaudeProviderTests
    CodexProviderTests
    CursorProviderTests
    GrokProviderTests

AppTests/
    UsageViewModelTests
    ProviderPresentationTests
```

Provider tests should use:

* fixture JSON
* temporary directories
* fake HTTP transports
* fake clocks where useful

Never touch live user credentials.

---

# 26. Refactor Rules

During this revamp:

### Prefer deletion over abstraction

Before adding an abstraction, ask:

> Can the requirement producing this complexity be removed?

### Prefer direct implementation over generic framework

Four known providers do not require a plugin architecture.

### Do not preserve dead compatibility accidentally

If a setting/source/format is intentionally removed, delete it.

### Do not add speculative flexibility

No "maybe we'll support 80 providers later" architecture.

### Keep boundaries strict

Core:

```text
models
state semantics
persistence primitives
```

Providers:

```text
credentials
local provider data
HTTP
decoding
```

App:

```text
macOS lifecycle
observable state
presentation
settings
```

---

# 27. `AGENTS.md` Cleanup

The repository's agent instructions currently encode a large amount of obsolete architecture.

After each feature deletion, delete the corresponding instructions.

Do not leave rules describing:

* notifications
* attention hooks
* resident Codex process pools
* statusline bridge if removed
* obsolete poll policy
* removed widget behavior

The final root `AGENTS.md` should describe architectural invariants, not an implementation history.

Target:

```text
product scope
module boundaries
provider contract
security rules
build/test commands
concurrency rules
persistence rules
```

Prefer short rules whose necessity is obvious from the architecture.

---

# 28. Documentation Cleanup

Update:

```text
README.md
SPECS.md
DESIGN.md
AGENTS.md
CHANGELOG.md
```

Do not let SPECS continue describing features that no longer exist.

Consider replacing the large historical specification with a much shorter current-product specification.

---

# 29. Migration Order

Do not implement this as one giant rewrite.

Use the following sequence.

## Phase 0 — Baseline

Before changing architecture:

* build Debug
* build Release
* run all tests
* capture current Swift source/file counts
* capture application launch RSS
* capture idle RSS
* capture idle CPU with popover closed
* capture CPU with popover open
* observe provider subprocesses
* record requests over approximately 15 minutes
* record wakeups if practical

Commit benchmark notes.

No optimization claim should be made without comparing against this baseline.

---

## Phase 1 — Delete Notifications

Remove notifications, predictive notifications, attention hooks and associated settings/tests.

Build and test.

Commit separately.

---

## Phase 2 — Complete

Local analytics and their supporting infrastructure are removed.

---

## Phase 3 — Service Status and Forecast Removal — Complete

Removed service-status requests, incident banners, depletion predictions, pace
markers, and the forecast menu-bar option. Preserved provider usage, balances,
reset countdowns, visual severity, and the widget.

Diagnostics, Advanced settings, and onboarding are separate future decisions. Provider normalization is described in Phase 6 below.

---

## Phase 4 — Widget Removal Complete

Removed the WidgetKit target, publication lifecycle, mirrored settings, and App Group
entitlement. Preserved menu-bar selection, quota presentation, and provider caches.
Claude snapshots now use Application Support. Existing standard settings need no migration.

---

## Phase 5 — Claude OAuth-only complete

Removed the statusline source, permanent bridge work, local activity selection, and
separate OAuth enrichment. A one-time migration removes exact legacy commands and captured
files while preserving user commands and the current refresh interval. Multi-account OAuth,
last-good persistence, and existing polling intervals remain. Provider normalization is described in Phase 6 below.

Analytics caches remain deferred to final obsolete-artifact cleanup: the app-owned
`~/Library/Application Support/ClaudeMeter/cost-usage-cache.json` can be materially large.
The small `~/Library/Caches/com.jewei.claudemeter/models-dev-pricing-v1.json` can be ignored.

---

## Phase 6 — Shared provider domain complete

Core now has `ProviderID`, `ProviderSnapshot`, `ProviderAccountSnapshot`, `UsageWindow`,
`BalanceItem`, and the existing `ReadingState`. Four provider-local adapters preserve
accounts, quota windows, resets, plans, balances and allowance details. AppState exposes a
computed projection. Polling, provider internals, old view helpers and persistence formats
remain unchanged. See SPECS.md for field and identity contracts.

---

## Phase 7A — Cursor/Grok UsageStore pilot complete

Added the Core fetch contract and thin adapters. UsageStore owns Cursor/Grok current,
stale and failed readings, loading, cancellation and supersession. Their cards now consume
normalized accounts, windows and balances. AppState retains global scheduling and
Claude/Codex lifecycle at this step. Phase 7B below moves Codex.

---

## Phase 7B — Codex lifecycle complete

Codex is one UsageProvider with multiple configured homes. UsageStore owns normalized
readings, loading and refresh acceptance. The Codex boundary validates account ownership,
handles partial failures and retains the existing last-good archive. Codex cards and main
meter selection consume normalized accounts. Phase 7C below completes Claude migration.

---

## Provider contract stabilization complete

UsageStore calls previous reconciliation, fetch, in-memory acceptance and persistence wait directly.
Publication callbacks and result-carried acceptance closures are removed. Validation,
fetch and acceptance use one refresh ID. Codex retains its ownership checks and archive
format. Claude is unchanged.

Phase 7B.2 separates fast acceptance from disk completion. `didAccept` updates only
in-memory metadata and submits ordered work. UsageStore then publishes and clears loading
before it awaits `waitForPersistence`. Codex archive reads, encoding and writes run on one
serial queue. Already accepted writes survive later refreshes and cancellation. Only the
newest queued archive remains in memory until the write wait completes, so a new refresh
can validate accepted data without waiting for disk.

## Phase 7C — Claude lifecycle complete

Claude is one provider with multiple normalized accounts. Validation restores compatible
last-good data off-main and removes disabled accounts. Primary OAuth and the secondary
300-second policy stay inside ClaudeProviderAdapter. Each account retains its own
successful observation time, stale state and sanitized failure. All unavailable accounts
produce a failed provider reading; mixed usable accounts remain current.

UsageStore accepts and publishes each result through the frozen contract. ClaudeReadingStore
orders accepted SnapshotStore operations on a serial queue. UI publication does not wait
for disk. Old disk fields remain at that boundary; the app no longer mirrors one account
into top-level Claude state. Provider-owned diagnostics retain typed credential failures.
Token refresh and shared 429 backoff remain independent of quota acceptance.

Optional web reset offers, their sign-in and polling are removed because they are reset
grants rather than usage, balance or authoritative reset countdowns. OAuth quota resets,
scoped windows, extra usage and account selection remain. Global scheduling is unchanged.

---

## Phase 7D — Scheduler extraction complete

RefreshScheduler owns timer tasks, pending/coalesced requests, provider admission, popover
interaction timing and power/network monitor lifetime. AppState supplies explicit settings
and delegates UI events. UsageStore still owns all provider execution and publication.
PollSource and PollConfiguration are removed. ProviderID and RefreshConfiguration replace
them. Task cancellation replaces global cycle IDs and the old pipeline generation.

Phase 7D preserved cadence. Phase 8 below replaces that policy.

## Phase 8 — Refresh policy complete

All enabled providers share a 300 s timer. Popover open and wake use the shared reading
freshness check at 60 s and 300 s respectively. UI age staleness defaults to 600 s; older
short preferences use that minimum. Manual refresh remains unconditional while active
and awake. Start refreshes immediately after onboarding.

SecondaryPollPolicy, the Claude fast exception, battery queries, NetworkMonitor and
asleep rechecks are removed. Settings refresh only affected providers without restarting
the timer. Provider-internal account timing, authentication, deadlines and persistence
remain unchanged. Reset countdowns update locally while the popover is visible.

### Refresh baseline and resource comparison

The Phase 7D source baseline used a 60 s timer, 120 s on battery, and 300 s asleep
rechecks. With the default 180 s UI threshold, idle secondary providers were admitted
every 120 s. Claude and the selected main provider ran each cycle. Open/recent popover
use, wake and reconnect admitted every provider; every popover open requested refresh.

Calculated periodic opportunities with all four providers enabled and no interaction:

| Condition | Before, per hour | After, per hour |
|---|---:|---:|
| AC, Claude selected | 150 | 48 |
| AC, Codex selected | 180 | 48 |
| Battery | 120 | 48 |
| Asleep timer rechecks | 12 | 0 |

These are upper bounds before fetch duration and provider-internal skips. They exclude
startup and user actions, and are not network request measurements. A deterministic test
advances twelve 300 s waits and checks twelve refreshes per provider plus startup.
No controlled OS-level CPU, resident-memory, wakeup or subprocess comparison was taken.

---

## Later phase — Simplify Grok

Convert Grok directly to the new provider contract.

It should be the reference implementation.

Build and test.

---

## Phase 9 — Codex source simplification complete

Before this phase, automatic mode preferred App Server, then direct OAuth. The source was
481 lines, its pool 209 lines, and pool tests 208 lines. One initialized process per home
could stay resident with five-minute polls and a ten-minute idle timeout.

Now healthy refreshes make one direct usage request per home and launch no subprocess.
Recovery launches one temporary process only for credential/auth failures. Tests use four
isolated homes, fake HTTP and local shell fixtures; they verify zero healthy launches,
one affected-home recovery, unchanged auth files, and process reaping after all outcomes.
No live-account application resource measurement was performed.

Upstream review used commit `30fc6864cc1318121eca1843c217fe00ce1212f1` on 2026-09-23.
The login auth manager refreshes and persists tokens through Codex-owned backends.
`account/read` can request that recovery; the app does not consume the refresh token itself.
File/keyring/auto storage can support recovery. Another process's ephemeral login cannot.

---

## Phase 10 — Cursor local storage complete

Before this phase, CursorTokenStore was 567 lines and its tests were 518 lines.
A cache miss launched one sqlite3 process. Cache hits avoided launch but still inspected
DB/WAL/SHM identities and SHM contents.

Now each detection opens system SQLite read-only, queries and closes. There is no
credential detection cache or Cursor subprocess. Temporary DB errors remain separate
from missing credentials. Tests use SQLite API fixtures for encoding, WAL updates,
checkpoint/removal, replacement, busy locks, special files and unchanged database data.
The separate Cursor refresh-token cache, source generations, endpoints and rotation
behavior are unchanged. UsageStore and RefreshScheduler are unchanged.

A local optimized benchmark used a 24,317,952-byte temporary database, with four
credential keys among 40,000 unrelated rows. Across 30 warm reads per path, median
time was 0.106 ms with direct SQLite and 4.090 ms with the old uncached subprocess.
This measures local credential reads, not idle app CPU/memory or old cache-hit cost.

---

## Poll architecture

Scheduler extraction and refresh-policy simplification are complete in Phases 7D and 8.
Provider-internal optimization remains separate work.

---

## Phase 12 — Shrink AppState

Move all remaining non-UI responsibilities into the correct layer.

Rename to `UsageViewModel` if that better describes the remaining type.

Goal:

```text
observable presentation state
user actions
small amount of UI transformation
```

No provider I/O implementation.

No subprocess handling.

No persistence implementation.

---

## Phase 13 — Simplify Popover

Render normalized provider cards.

Remove provider-specific duplicate presentation paths where possible.

Maintain current visual identity unless deliberately redesigning it.

Stop all continuous UI animation/timers while hidden.

---

## Phase 14 — Settings Cleanup

Remove obsolete settings and tabs.

Reorganize around the current product rather than historical features.

---

## Phase 15 — Test Cleanup

Break giant test files into focused suites.

Delete tests for removed architecture.

Prefer behavioral tests over tests that freeze implementation details.

---

## Phase 16 — Documentation and Agent Rules

Rewrite documentation to reflect the resulting architecture.

Make `AGENTS.md` significantly shorter.

---

## Phase 17 — Measure Again

Repeat Phase 0 measurements.

Compare:

```text
release binary size
Swift production LOC/bytes
file count
launch RSS
idle RSS
idle CPU
popover-open CPU
wakeups
subprocess count
network requests/hour
launch time
```

The revamp succeeds only if complexity and resource use materially decrease without reducing the target product's reliability.

---

# 30. Acceptance Criteria

The architecture revamp is complete when:

* notifications are fully removed
* Usage & Spend is fully removed
* transcript scanning is gone
* cost/pricing machinery is gone
* four providers use a common snapshot contract
* provider failures are isolated
* stale last-good readings work consistently
* `AppState` no longer coordinates the entire application
* Codex does not keep a resident subprocess unless proven necessary
* Cursor does not launch `sqlite3`
* hidden popover UI does not continuously animate
* background provider refresh frequency is measured in minutes, not seconds
* reset countdowns update locally
* provider-specific logic does not leak into generic UI/store code
* obsolete settings and tests are gone
* `AGENTS.md` is substantially shorter
* all supported flows have focused tests
* Debug and Release builds pass
* resource measurements improve over baseline

---

# 31. Implementation Discipline for Codex

Work phase by phase.

For every phase:

1. Inspect current callers before deleting anything.
2. State exactly what will be removed or changed.
3. Make the smallest coherent patch.
4. Format.
5. Run focused tests.
6. Run package tests.
7. Build the app.
8. Fix failures before starting another phase.
9. Summarize:

   * files deleted
   * files added
   * significant architecture changes
   * test results
   * remaining obsolete code discovered

Do not silently expand scope.

Do not redesign unrelated UI while changing provider architecture.

Do not create compatibility layers merely to make old architecture coexist indefinitely.

Temporary adapters are acceptable only when they enable a staged migration and have an explicit later deletion phase.

---

# 32. First Task

Begin only with **Phase 0 and Phase 1**.

Do not start the provider architecture rewrite yet.

First:

1. establish the baseline,
2. map all notification/attention dependencies,
3. remove the notification/attention feature completely,
4. update affected tests/docs/agent instructions,
5. run the full verification suite,
6. report what became newly dead or simplifiable.

Stop after Phase 1 and report the result before proceeding to Phase 2.
