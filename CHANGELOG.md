# Changelog

All notable changes to Claude Meter are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- Add entries under [Unreleased] as you work. On release, scripts/release.sh
     promotes this heading to the new version, stamps the date, and uses the
     section body as the GitHub release notes. Keep entries user-facing. -->

## [Unreleased]

### Added

- The menu-bar item has a spoken summary for VoiceOver, including the provider,
  quota window, percentage meaning, and paused or stale state.

### Changed

- Remove the extra Claude heading when Codex is the main meter. Each provider
  card already shows its name.
- Releases retain app and widget debug symbols that match the shipped binaries.

### Fixed

- Cursor credential reads no longer crash or launch abandoned commands when startup times out.
- Valid Codex quotas remain available when optional credit or reset metadata is malformed.
- Claude usage backoff survives an app restart and still applies to all accounts.
- Copied transcript history counts once within each account. Unique continuations and
  separate accounts still contribute to cost totals.

## [2.15] - 2026-09-05

### Added

- **Codex cards show usage limit resets.** View the available count, reset type,
  and expiry time, including when Codex is the secondary provider.

### Changed

- **Long reset countdowns include hours.** Weekly limits and other countdowns
  now show `6d 7h` instead of rounding down to whole days.

### Fixed

- **Local tests preserve the installed app's polling setting.** Running tests
  can no longer pause the app and remove the menu-bar percentage.

## [2.14] - 2026-08-28

### Added

- **A Forecast menu-bar option** pairs the nearest quota percentage with its
  projected run-out time.
- **Secondary Claude details can now expand in place.** When Codex is the main
  meter, Claude’s compact card can reveal each account’s limits, reset timing,
  plan, and identity details without taking over the popover.

### Changed

- **Account-card forecasts are concrete.** When the current burn rate may exhaust
  quota before refill, cards now say when instead of showing an abstract pace gap.

## [2.13.1] - 2026-08-28

### Fixed

- **OAuth throttling no longer looks like a broken connection.** Settings now says
  Anthropic is rate-limiting usage checks and will retry automatically, while an
  already verified Keychain connection remains shown as connected.

## [2.13] - 2026-08-28

### Changed

- **Provider cards now open and close smoothly while the popover follows their size.**
  Expanded details are revealed without shaking the fixed header, Reduce Motion is
  respected, and the window stays attached to its menu-bar item through rapid
  reversals and display changes.
- **Cursor and Codex use refreshed, dark-mode-friendly provider icons.**

### Fixed

- **An expired reading from a stale cache no longer looks like a full tank.** When
  Claude Meter cannot observe usage accumulated after a reset, it now shows that
  window as unknown and explains how to refresh instead of claiming 100% energy.
- **Enabling the OAuth source no longer looks like completing its connection.**
  Settings now labels the source as not connected and always exposes the required
  Connect or manual-entry actions instead of leaving the setup area blank.

## [2.12.1] - 2026-08-22

### Fixed

- **Codex banked resets appear again, and current Codex versions no longer make
  Claude Meter quit.** Codex removed its old `untrusted` approval mode, so App
  Server exited at startup. Claude Meter then fell back to OAuth data without
  banked resets and could receive `SIGPIPE` while it initialized the closed
  process. It now uses the supported noninteractive mode.

## [2.12] - 2026-08-12

### Changed

- **Claude Meter stays responsive when shared snapshot storage stalls.** Snapshot
  reads and writes now have bounded waits and fail fast after a timeout, so a
  wedged App Group container cannot freeze polling or consume another blocked
  thread on every cycle.
- **Fresh quota data no longer waits for Anthropic's service-status page.** The
  advisory status check now runs independently and coalesces overlapping refreshes,
  so a slow status request cannot delay the authoritative usage reading.
- **Claude Meter gives memory back under system pressure.** Rebuildable cost and
  activity caches are released when macOS asks, while the last persisted cost
  checkpoint remains available for future launches.

### Fixed

- **OAuth-only details now have their own freshness state.** If refreshing Opus,
  scoped limits, extra usage or plan details fails, the last good values remain
  visible but are clearly marked stale in the popover and Diagnostics. A successful
  response can also remove limits that Anthropic no longer reports instead of
  leaving old values behind.
- **Misbehaving provider helpers can no longer grow memory without bound.** Output
  captured from Codex and Cursor subprocesses is capped and continuously drained,
  preventing oversized or unterminated responses from wedging the helper path.

## [2.11] - 2026-08-12

### Added

- **Account cards now show whether usage is on pace.** Bar cards include a subtle
  marker for where usage would be at the current point in the window; both card
  styles say how far ahead or behind that pace you are. The marker mirrors when
  switching between energy-left and usage views, and pace never changes alert
  colors or thresholds.
- **Claude Meter now says when Anthropic is throttling it.** A rate-limited usage
  check used to look identical to the app being broken — the numbers just stopped
  moving, with the cause buried in Diagnostics. The popover and Settings now name
  it and count down to the retry ("retrying in 48m"), in the quieter style used
  for problems that clear on their own.

### Changed

- **Opening Claude Meter always fetches fresh figures.** Between checks the app
  serves its last reading, so opening the popover could show numbers up to two
  minutes old, marked stale. Opening it now counts as asking, and fetches — while
  background checks stay throttled, so this doesn't mean more traffic.
- **Fewer usage checks when you aren't in a Claude Code session.** With no live
  session the app was querying Anthropic every minute for figures that move over
  hours and days, which risks being rate-limited for the trouble. It now checks
  every two minutes — still well inside the window before data is marked stale.
- **Multi-account failures are easier to diagnose.** One account failing no longer
  hides why while healthy accounts update; Claude Meter preserves the previous
  reading as stale and reports the account-specific failure in Diagnostics.

### Fixed

- **Alerts no longer fire retroactively when Claude Meter launches.** The first
  successful reading establishes a baseline instead of treating an already-high
  usage level as a threshold crossing that happened while the app was closed.
- **Your Opus weekly limit won't disappear when Anthropic changes how it reports
  it.** Model-specific weekly limits are moving to a new field in the usage API,
  and the old one has been seen going empty during the switch. Claude Meter now
  reads both, so on a Max plan the Opus limit — usually the one that actually
  binds — keeps driving the menu bar, alerts and widget instead of quietly
  vanishing. Limits for models it hasn't seen before now show up too.

- **Claude Meter's own test suite could read the login Keychain.** A safeguard
  meant to block Keychain access from tests only recognised one of the two ways
  Apple's tooling runs them, so the checks a developer runs locally were reaching
  real credentials instead of being refused. Ships in no released build and never
  affected the app itself — the safeguard now detects both.

- **Claude Meter now backs off properly when Anthropic rate-limits it.** The usage
  API has been seen answering "too many requests" with a retry delay of zero while
  still refusing to serve — which we took at face value and kept asking, instead of
  waiting the intended minute. A useless delay is now ignored in favour of our own.
- **A rejected sign-in no longer shadows a good one.** After a failed token refresh
  while filling in Opus and extra-usage details, the dead credential stayed cached
  and outranked the fresh one Claude Code had written, so signing in again didn't
  always take effect until you restarted the app.
- **OAuth connection errors are no longer silently ignored.** Explicit connect,
  save and disconnect actions now surface Keychain write failures, while Settings
  can still check credential availability without reading the secret itself.
- **Local cost and activity totals are more resilient.** Rewritten transcripts,
  incomplete final lines, unreadable account roots and duplicate events across
  discovered roots no longer silently distort the result; partial scans are
  identified instead of replacing the union with zero.
- **The widget refreshes when data becomes stale**, rather than waiting for its
  next ordinary timeline update to change the stale indicator.
- **The widget's headline number now accounts for the weekly Opus limit.** It was
  computed from the session and all-models weekly windows only, so on a Max plan
  the rings could read 55 while the Opus row right beneath said 4%.
- **The popover no longer claims your accounts are full before it has data.**
  With no readings yet it said "All 2 accounts fresh" under a "Warming up"
  headline; it now says it's still warming up.
- **Copy Sanitized Diagnostics** no longer includes Codex account display names
  verbatim. The name is free text, so anyone who names an account after its email
  was pasting that address into a report meant to be safe to share.
- A Codex **Go** plan is labelled Go rather than Plus.
- The widget's "updated" time ticks instead of freezing at whatever it read when
  the widget was last redrawn.

## [2.10] - 2026-07-27

### Added

- **Claude Meter now tells you when your Claude Code sign-in has a problem.**
  Previously an expired or revoked sign-in failed silently — the app fell back to
  other sources and the numbers simply stopped moving, with the cause visible
  only in Diagnostics. The popover and Settings now name the problem and the fix
  (usually `claude login`). Transient states such as a locked Keychain are shown
  in a quieter style, since they clear on their own.
- **Cursor, Codex and Grok cards collapse.** Collapsed still shows the provider,
  its plan, the percentage, the bar and when it resets — everything you open the
  app to check — while the breakdown rows hide. What you expand is remembered.
- **A proper Codex logo**, replacing the star that could look like a warning.

### Changed

- **The popover fits on a laptop screen.** It used to grow to whatever its
  contents needed, so running two Claude accounts alongside Cursor and a couple
  of Codex accounts ran off the bottom of a 13" display. It now sizes to its
  content up to what the screen can show, and scrolls beyond that — so any
  combination of accounts and providers fits.
  - **Provider cards start collapsed after this update.** If you preferred
    Cursor's or Codex's full breakdown, one click on the card reopens it and it
    stays that way.
  - **Last 7 days** is a single line with the total. It's still the way into the
    activity heatmap.
  - **The footer is gone.** Settings and Quit moved to the top of the popover.
- **Each provider's plan now sits beside its name** as a badge, the way Claude
  accounts already showed Max and Pro. Codex plans are shown exactly as Codex
  reports them, so a Pro 5X account and a Plus account no longer both read as
  "Pro" — if the name you gave an account disagrees with its actual plan, you can
  now see that without expanding the card.
- **Pause moved to Settings → Advanced**, and the Claude Code version moved to
  **Settings → About**, where the "update available" flag still appears.
- **The refresh button is gone.** Opening the popover already refreshes, so the
  button only repeated what had just happened.

## [2.9] - 2026-07-27

### Changed

- **Turning off the Statusline source now uninstalls its bridge.** Previously
  the snippet stayed in every account's `settings.json` and Claude Code kept
  writing session files indefinitely, with no way to undo it from the app.
  Disabling the source now removes the snippet and clears the captured session
  data; your own statusline command is preserved.
- **A Cursor problem no longer affects the Claude reading.** An expired Cursor
  token used to blank the menu-bar percentage and grey the status dot, even
  though Claude data was arriving normally. Cursor issues now stay on Cursor's
  own card, matching how the menu bar has always been documented to behave.
- **Less background work while idle.** The widget no longer rebuilds its
  timeline every minute when nothing has changed, the local cost cache writes to
  disk far less often, and the Anthropic service-status and Cursor sign-in
  checks are cached instead of repeating on every poll.

### Removed

- The unused usage-history recording. It sampled your limits every poll and
  wrote them to disk, but nothing in the app ever displayed the data. Its file
  is deleted automatically on first launch.

### Fixed

- **Connecting Claude Code could leave the OAuth source permanently stuck.** If
  the stored token happened to be expired at the moment you pressed Connect,
  setup reported success but every later refresh failed, and the source stayed
  dead until Claude Code next refreshed its own credentials. The same fault
  could also appear after the app had been running for a while. Both paths are
  fixed. If you are already stuck, this update prevents it recurring but cannot
  revive the spent credential — run `claude login` once and the app picks up the
  refreshed token automatically.
- **The wrong account could hold the menu bar.** With two or more Claude Code
  windows open on one account, that account looked continuously active and
  outranked the account you were actually working in. The meter now tracks real
  API activity per session.
- **Codex fell back to its second source far too rarely.** When the Codex CLI
  was installed but its app-server failed — a timeout, or a version that no
  longer answers — the card showed an error instead of reading your usage
  directly. It now falls back whenever the app-server can't answer.
- **Cost estimates could silently understate spend.** If the live price list
  omitted a model's cache rates, those tokens were priced at zero — and cache
  traffic is the bulk of Claude Code usage. Missing rates now fall back to
  Anthropic's standard ratios.
- **Rate-limit backoff could end early**, letting the app retry sooner than the
  API asked. `Retry-After` deadlines expressed as a date are now honored too.
- A Claude account reached through a non-default config directory now keeps the
  display name and plan you assigned it when there's no live session.
- Cursor credentials are read through the system Keychain API instead of a
  command-line helper, so the read can no longer trigger a blocking permission
  dialog.

## [2.8.1] - 2026-07-20

### Fixed

- Closing the popover no longer leaves its animations running in the hidden
  window. The app could idle at ~20% CPU (High energy impact) whenever a
  Claude Code session was open or a poll was in flight; it now drops to ~0%
  with the popover closed. The pulsing session and menu-bar dots also tick at
  a gentle rate instead of the full display refresh rate.

## [2.8] - 2026-07-18

### Added

- Clicking a Claude Attention notification now returns to its originating
  Ghostty, Terminal, iTerm2, or WezTerm tab when possible, with a safe app-focus
  fallback for Warp and stale routes.
- Diagnostics now show a bounded, non-sensitive statusline, OAuth, and cache
  attempt trail.
- Optional predictive alerts warn when a fresh two-poll forecast says session or
  weekly energy may run out before reset.
- Codex can monitor multiple accounts through separate `CODEX_HOME` directories.
  Each account gets its own card, display name, polling state, and retained last
  reading when another account fails.
- Scoped weekly limits the OAuth API reports beyond Opus (Sonnet, Cowork, …)
  now show as extra rows on the active account's card.
- Codex usage keeps working with newer app-servers that report windows by limit
  id instead of the positional session/weekly pair.

### Changed

- Reset times are standardized everywhere: minutes under an hour, hours under
  48 hours, and whole days beyond that ("resets in 4 days") — never a calendar
  date like "20 Jul".
- Codex cards show their reset timing, omit empty credit balances, and no longer
  include the Trends panel.
- OAuth setup checks Keychain item attributes passively and reads Claude Code's
  credentials only after explicit consent.
- A single local verification command now runs Core tests plus unsigned Debug
  and Release builds; releases validate signed artifacts before changing git.

### Fixed

- Turn-finished notifications now ignore subagent completions, so parallel
  workers do not alert before the main Claude turn has finished.
- Clicking an attention notification now reliably brings Ghostty/WezTerm to the
  front, never relaunches a terminal that has quit, and a hung focus helper can
  no longer stall the app's background work.
- Predictive alerts keep their two-poll confirmation across source-tier
  switches and reset-time jitter, break the streak when a poll fails, and use
  the same duration wording as the popover's forecast line.
- Diagnostics source-attempt labels are truthful: "not connected" is no longer
  reported as "disabled", and a bridge that never produced data is no longer
  reported as "stale".
- Connecting Claude Code in Settings no longer risks freezing the UI while
  macOS shows a Keychain permission prompt.

## [2.7] - 2026-07-16

### Added

- **Richer provider cards.** Cursor now shows its plan and Auto + Composer/API
  split. Codex now shows its plan, available usage resets, and the nearest reset
  expiry when Codex provides the detail.
- **Live session indicator.** The active Claude account shows a pulsing green dot
  while its statusline bridge is fresh. Reduce Motion keeps the dot static.

### Changed

- **More complete local usage estimates.** Cost totals and activity now include
  Claude subagent transcripts without counting context-fork replays twice. Cost
  estimates also price Claude Code's one-hour cache writes at the correct rate.
- **Faster repeat heatmap loads.** The activity scanner caches parsed transcript
  buckets for the app session. It also stops a scan when the heatmap closes and
  shows a spinner while the first scan is running.

### Fixed

- Launch at Login now explains when macOS approval is still required and links
  directly to the Login Items settings page.
- Closing Sparkle's update window no longer leaves an open Claude Meter Settings
  window without normal app focus or Command-Tab access.

## [2.6] - 2026-07-13

### Added

- **Grok usage** — an opt-in Data source for Grok Build (xAI CLI) weekly credit
  usage, shown as its own popover card like Cursor and Codex. Reads the `grok`
  CLI's sign-in; unofficial endpoint, may break without notice.
- **Per-account live usage for every Claude account** — plan, email, weekly
  Opus, and extra-usage now appear for *all* your `CLAUDE_CONFIG_DIR` accounts,
  not just the active one, read directly from each account's own login. Idle
  accounts no longer need an open Claude Code session to show their energy.
  Requires the Claude Code token source to be connected (Settings → Data);
  macOS asks once per account to allow the Keychain read — choose
  "Always Allow" to keep it silent.
- **"Same login" badge** — two config dirs signed into the same Claude account
  are flagged on their cards (they share one quota, shown twice).
- **Max 5x / Max 20x plan names** — the plan badge now shows the subscription
  multiplier when Anthropic reports it, instead of a bare "Max".

### Fixed

- Codex usage reads ignore auth-override environment variables
  (`CODEX_API_KEY`, `OPENAI_BASE_URL`, …) inherited from a terminal launch, so
  they can't point the reading at a different account.

## [2.5.1] - 2026-07-06

### Fixed

- **Codex usage now matches Cursor's percent semantics** — the Codex card shows
  percent used, fills upward, and labels weekly usage as used instead of left.

## [2.5] - 2026-07-06

### Added

- **Codex usage** — an opt-in Data source for Codex usage, shown as its own
  popover card like Cursor while leaving Claude's menu-bar, widget, and
  notifications unchanged. Auto mode prefers the Codex CLI App Server, with a
  read-only direct OAuth fallback for file-backed Codex logins.

## [2.4] - 2026-06-30

### Added

- **Trends** — a new screen in the popover (tap the **📈 Trends** card) charts your
  usage over time as per-window sparklines: the 5-hour session, the week, and the
  weekly Opus window. It builds up as you use Claude and shows "building history"
  until there's enough to plot.

### Changed

- **Faster launches.** Local cost-usage history is now cached to disk, so Claude
  Meter no longer re-scans every transcript on startup — only new activity is read.
- **"Refueled" notifications are more reliable** — they now fire even when a limit
  reset while Claude Meter was closed.

### Fixed

- **Launch at Login** no longer switches itself back off when macOS leaves the
  login item pending approval (common after a first launch or a macOS update).
- A stalled network read can no longer freeze refreshes — the poll loop always
  recovers on the next tick.
- No more spurious "signed out" after waking from sleep or changing networks
  (overlapping token refreshes are coalesced into one).
- After updating Claude Code, Claude Meter reads your most recently used
  credentials instead of an older leftover Keychain entry.

## [2.3] - 2026-06-30

### Removed

- The **Claude.ai web-session source** (Settings → Data) and its "Import from
  browser" cookie import. Claude Meter now collects usage from the **Statusline
  Bridge** and **Claude Code OAuth** only — trimming the app's most fragile and
  privacy-sensitive code (reading browser cookies). If you used only the
  claude.ai source, connect via the statusline bridge (just run Claude Code) or
  Claude Code OAuth.

## [2.2] - 2026-06-29

### Added

- **"Claude is waiting" notifications** — get a native macOS notification the
  moment a Claude Code session finishes its turn or asks for permission, so you
  can step away and get pulled back exactly when it needs you. Works across all
  your accounts. Turn it on under Settings → Notifications → Claude Attention
  (separate toggles for turn-finished and permission-needed).
- **Run-out forecast** — account cards project when you're on pace to hit a
  limit, not just how much energy is left right now.
- **Outdated Claude Code warning** — the popover footer flags when your installed
  Claude Code is behind the latest release and links to the changelog.

### Changed

- **More accurate cost estimates** — per-model pricing is now pulled live from
  models.dev, with corrected built-in fallback rates (Opus was previously
  over-estimated by roughly 3× when the live rates were unavailable).

### Fixed

- **Sturdier sign-in** — OAuth token refresh now prefers fresh in-memory
  credentials over a stale Keychain entry, avoiding spurious signed-out states.

## [2.1] - 2026-06-28

### Added

- An **activity heatmap** — tap the "Last 7 days" cost card to flip the popover to
  a GitHub-style punchcard showing when you actually work (day of week × hour of
  day, shaded by message volume), scanned from your local transcripts. Tap **Back**
  to return.
- A **"Menu bar shows"** setting (Appearance) to choose which window the menu-bar
  percentage reflects: nearest limit (default), the 5-hour window, the weekly
  window, or **both** side by side (e.g. `99% 5h · 73% 7d`).
- The **Claude Code version** now appears in the popover footer and links to the
  changelog.

### Changed

- Account cards show the weekly reset as a **calendar date** (e.g. "29 Jun")
  instead of a bare weekday.
- Removed the footer "Add account" button (adding an account already lives in
  Settings, reachable via the gear) to free up space.

## [2.0] - 2026-06-26

### Added

- Appearance settings (new Settings tab): pick **activity rings or energy bars**
  for the account cards, switch between showing **energy remaining or usage**, and
  **pin the menu-bar percentage to a specific account** (or the nearest limit).
- A complete visual redesign — a playful, energy-themed interface with a
  combined-health hero, per-account **activity rings** (weekly + 5-hour), and the
  whole app reframed as "energy remaining". Real Fredoka & Nunito typography and a
  refreshed green-bolt app icon.
- Per-account **display name** and **plan badge**, set in Settings → Data, so each
  account reads how you want (rate limits are per-account).
- A "refueled" notification when an account that was running low recovers — its
  window drops back to normal or resets.

### Changed

- The menu-bar icon is now an energy bolt with a nearest-limit status dot (across
  all your accounts) plus your energy-left percentage.
- Settings is fully restyled (Data / Notifications / Advanced / About) with a bold
  tab bar, color-coded threshold sliders, and roomier multi-account rows.
- The widget adopts the activity-ring look and adapts to light and dark.
- Cursor usage requests now use the shared redirect-guarded provider transport,
  matching the credential-leak protections used by Claude sources.
- OAuth-only enrichment for statusline/claude.ai snapshots is cached and
  throttled to reduce redundant usage API calls while keeping Opus/extra/plan
  fields visible between refreshes.

### Fixed

- Multi-account notifications now diff each account against its _own_ previous
  reading, so an active-account switch never fabricates a false threshold crossing
  nor skips a real one (switching to an already-critical account surfaces it once).
  A "refueled" alert still won't trigger from a stale/persisted reading on first
  launch or the first OAuth Opus enrichment.
- Disabling an account now clears any menu-bar pin to it (and the Appearance
  picker no longer lists disabled accounts); a lone non-default config dir shows
  its custom display name and plan badge in the popover.
- The menu-bar percentage and status dot are now Claude-only — Cursor usage no
  longer leaks into the menu bar (it kept its own popover card) and the menu bar
  honors the "Menu bar follows" account setting.
- OAuth refreshed-token cache is now scoped to the selected mode (`auto` vs
  `manual`) and cleared on disconnect, preventing tokens from crossing source
  modes inside one app session.
- Stale statusline/cache snapshots now mark the menu bar and popover as stale
  immediately instead of waiting for the age-based stale threshold.
- Medium widget now shows the Opus weekly window when available, matching the
  large widget and menu-bar severity.

## [1.3] - 2026-06-24

### Added

- Usage pace badge on each window card ("On track" / "Running hot" / "Room to
  spare"), comparing how much you've used against how far through the window you
  are — a glanceable read on whether you'll make it to the reset.
- Weekly Opus usage window, shown as its own card and factored into the menu-bar
  severity and notifications. For Max plans this is often the limit you hit first.
- Pay-as-you-go "Extra usage" overage spend (with a progress bar) is surfaced in
  the popover, including when overage billing is paused.
- Opus weekly, extra-usage spend, and plan now appear even on the statusline
  source: when OAuth is connected, those OAuth-only fields enrich the snapshot.
- Per-model token and estimated-cost breakdown for the last 7 days, scanned from
  local Claude Code transcripts and shown in the popover.
- Anthropic service-status banner in the popover during incidents, so an outage is
  distinguishable from expired credentials.
- Plan badge (Max/Pro/Team/Enterprise) in the popover header when detectable.
- "Import from browser" for claude.ai setup: reads the session key from Chrome,
  Brave, Edge, Arc, Firefox, or Safari and auto-detects the org — no manual paste.
- Diagnostics has a "Check browsers" action reporting per-browser cookie-import
  status (no secrets), to help troubleshoot the import.

### Changed

- Background polling is now energy-aware: it pauses entirely while the display or
  system is asleep (refreshing immediately on wake) and stretches its cadence while
  on battery, to cut idle power draw when you're away or unplugged.
- Network requests now go through a shared, redirect-guarded transport that blocks
  off-origin and HTTPS→HTTP redirects (so credentials can't leak), with bounded
  retries on transient failures. Keychain reads distinguish a momentary lock from
  missing credentials, so a locked Keychain no longer looks like "not connected".
- claude.ai setup now auto-detects your organization ID from the session key — the
  Org ID field is optional; leave it blank and Claude Meter resolves it for you.
- The OAuth usage source now backs off when Anthropic rate-limits (429), honoring
  `Retry-After`, and identifies as the Claude Code CLI. Usage decoding tolerates
  missing or null fields instead of failing the whole refresh.
- When paused, the menu bar shows only a dimmed icon and hides the usage
  percent, making the inactive state clearer.
- Release tooling derives the marketing version and build number automatically,
  bakes them into the build, and uses this changelog as the GitHub release notes.

### Fixed

- OAuth enrichment now shares the same 429 backoff as the main OAuth pipeline, so
  statusline-primary users no longer hammer the usage API after a rate limit.
- Plan badge no longer disappears after an in-session OAuth token refresh
  (`subscriptionType` is preserved).
- Menu-bar usage percent now reflects the binding limit (including Opus weekly),
  matching severity icon semantics.
- Browser cookie import matches `claude.ai` hosts exactly (not substring matches
  like `evilclaude.ai`).
- Cost estimates label "partial" when large transcript files are tail-read; dedup
  no longer collapses messages missing ids.
- Pace badges treat implausible `resets_at` values as unknown instead of
  clamping to misleading hot/cold readings.
- PowerMonitor no longer parks polling on `willSleep` (cancelled sleep could
  stall refreshes for up to 5 minutes).
- Poll and cursor errors shown in the UI are sanitized like bridge diagnostics.
- Service-status fetch runs concurrently with usage polling (no longer blocks the
  primary refresh).
- Widget shows Opus weekly when available; release script tags the release commit
  (not pre-build HEAD) and reads `TEAM_ID`/`APPLE_ID` from env.

## [1.2] - 2026-06-24

### Added

- Cursor as an optional, opt-in usage source alongside Claude.

### Changed

- Hardened the core pipeline for correctness and steadier polling.

## [1.1] - 2026-06-24

### Added

- Statusline bridge and OAuth usage API as primary data sources.
- Per-source toggles and active-state handling.
- App icon, plus onboarding and settings polish.

### Changed

- More resilient usage data sources and diagnostics.

### Fixed

- Usage flicker, idle staleness, and the refresh spinner.

### Removed

- SQLite history store and the floating mini monitor.

## [1.0] - 2026-06-23

### Added

- Menu bar usage meter for Claude Code with five-hour and weekly rate-limit windows.
- Data-source fallback: statusline bridge → OAuth usage API → claude.ai API → cached snapshot.
- Local notifications with threshold deduplication.
- WidgetKit widget sharing snapshots via an App Group.
- Settings panel and diagnostics view.
- Sparkle auto-update support.

[Unreleased]: https://github.com/jewei/claude-meter/compare/v2.15...HEAD
[2.15]: https://github.com/jewei/claude-meter/compare/v2.14...v2.15
[2.14]: https://github.com/jewei/claude-meter/compare/v2.13.1...v2.14
[2.13.1]: https://github.com/jewei/claude-meter/compare/v2.13...v2.13.1
[2.13]: https://github.com/jewei/claude-meter/compare/v2.12.1...v2.13
[2.12.1]: https://github.com/jewei/claude-meter/compare/v2.12...v2.12.1
[2.12]: https://github.com/jewei/claude-meter/compare/v2.11...v2.12
[2.11]: https://github.com/jewei/claude-meter/compare/v2.10...v2.11
[2.10]: https://github.com/jewei/claude-meter/compare/v2.9...v2.10
[2.9]: https://github.com/jewei/claude-meter/compare/v2.8...v2.9
[2.8.1]: https://github.com/jewei/claude-meter/compare/v2.8...v2.8.1
[2.8]: https://github.com/jewei/claude-meter/compare/v2.7...v2.8
[2.7]: https://github.com/jewei/claude-meter/compare/v2.6...v2.7
[2.6]: https://github.com/jewei/claude-meter/compare/v2.5.1...v2.6
[2.5.1]: https://github.com/jewei/claude-meter/compare/v2.3...v2.5.1
[2.5]: https://github.com/jewei/claude-meter/compare/v2.3...v2.5
[2.4]: https://github.com/jewei/claude-meter/compare/v2.3...v2.4
[2.3]: https://github.com/jewei/claude-meter/compare/v2.2...v2.3
[2.2]: https://github.com/jewei/claude-meter/compare/v2.1...v2.2
[2.1]: https://github.com/jewei/claude-meter/compare/v2.0...v2.1
[2.0]: https://github.com/jewei/claude-meter/compare/v1.3...v2.0
[1.3]: https://github.com/jewei/claude-meter/compare/v1.2...v1.3
[1.2]: https://github.com/jewei/claude-meter/compare/v1.1...v1.2
[1.1]: https://github.com/jewei/claude-meter/compare/v1.0...v1.1
[1.0]: https://github.com/jewei/claude-meter/releases/tag/v1.0
