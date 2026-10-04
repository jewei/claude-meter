# Changelog

This changelog records notable changes to Claude Meter at each release. [The
specification](SPECS.md) defines current behavior.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- Add entries under [Unreleased] as you work. On release, scripts/release.sh
     promotes this heading to the new version, stamps the date, and uses the
     section body as the GitHub release notes. Keep entries user-facing. -->

## [Unreleased]

## [3.1.3] - 2026-10-04

### Fixed

- A Claude account card shows the plan that its login reports, such as Max 5x. An older
  manual badge from Settings no longer hides it.
- **Tokens used** on a Claude or Codex card counts only the records in that account's
  config dir or Codex home. Before, each card showed the total of all accounts on this
  Mac.

## [3.1.2] - 2026-10-04

### Fixed

- Quota refreshes bypass the local HTTP cache to request current provider readings.
- Card reordering uses a drag inside the popover. Text dragged from another app cannot
  change the card order.
- Token history scans resume across refreshes in large folders, so later files can be
  found within the scan limits.
- Slow token history configuration reads no longer use the capacity reserved for Codex
  quota configuration.

## [3.1.1] - 2026-10-03

### Added

- Expanded provider cards show tokens used today, yesterday, and in the last seven
  days. Claude, Codex, and Grok totals use local records on this Mac. Cursor totals use
  account usage. No prices are shown.

### Changed

- Improved card surfaces, ring lighting, button feedback, and dark-mode contrast.
- Settings has clearer sections, larger controls, and visual previews for rings and
  energy bars. Long account names and plan badges wrap more clearly.
- Paused and empty states provide a direct path to Settings.

### Fixed

- At zero energy left, the hero says "Take a breather" and "Out of energy".
- Cards and the popover window resize together when cards expand or collapse.
- Account headers, bars, and rings agree when a limit window resets. Stale expired
  windows remain unknown, and ring cards retain account errors and stale status.
- Hero reset text names the limiting window, so an earlier reset of another window does
  not imply that quota is available again.
- Codex configuration and archive preflight have bounded waits. Startup and Codex home
  checks run off the UI thread, and late configuration results cannot replace newer
  ones.
- Automatic retries preserve server wait times instead of shortening them to eight
  seconds.

## [3.1] - 2026-09-25

### Added

- Claude account cards show usage-limit resets, such as a model-launch reset, with the
  time left to use each one.
- Drag cards in the popover to change their order. The first card is the main meter. The
  menu bar, hero, and header time follow it. **Use automatic order** in **Settings**,
  under **Appearance**, then **Account cards**, restores the default order.
- Bar cards show a Session bar and a Weekly bar when the account reports both windows.

### Changed

- Each account has its own card, for Claude and Codex alike. Provider labels and
  provider summary cards are removed.
- With Energy bars, all Claude and Codex cards use one collapsible layout.
- The menu bar shows the 5-hour value by default. When an account has no 5-hour window,
  such as Codex Pro, it shows the weekly value.
- Appearance no longer has Main meter, Main meter follows, or the Nearest menu-bar
  option. Drag a card to the top to choose the main meter. A saved Nearest setting
  changes to 5h.
- Popover cards no longer show the account email.
- Claude config directories and Codex homes in Data settings use the same layout and add
  button.

### Fixed

- An expired login on one Claude account no longer shows "Refresh failed" for all Claude
  accounts.
- "1 usage reset available" is now singular.

## [3.0.2] - 2026-09-25

### Changed

- The critical menu-bar dot pulses three times when a limit becomes critical, then stays
  still.

### Fixed

- A slow Codex account no longer delays usage checks for the other Codex accounts.
- Renaming a Codex account no longer restarts the Codex usage check for each keystroke.

## [3.0.1] - 2026-09-25

### Added

- Codex account cards show available usage resets and their expiry details during normal
  usage checks.

### Fixed

- Automatic Claude and Cursor connections no longer consume refresh tokens owned by
  Claude Code or Cursor. Renew expired credentials in the owning app. Manual Claude
  credentials still support refresh.
- Codex ChatGPT logins work when the auth file also contains an API key.
- Cursor and Grok no longer retain the previous login's usage after a credential change.
- Legacy event-file cleanup retries failed deletions, including failures from the
  previous migration.

## [3.0] - 2026-09-23

### Changed

- Claude Meter now focuses on current usage, balances, and quota reset countdowns for
  Claude, Codex, Cursor, and Grok.
- Claude usage requires OAuth. Connect Claude Code credentials or enter OAuth
  credentials in Settings. Account selection no longer uses local session activity.
- All enabled providers refresh every five minutes while the display is awake. Opening
  the popover refreshes missing, failed, stale, or at least one-minute-old data. Reset
  countdowns update locally. The default age threshold for stale data is ten minutes.
- Display sleep stops refresh work. Wake checks freshness before requesting data.
  Provider settings changes refresh only the affected provider.
- Codex reads usage through direct OAuth. Only credential or authentication failures
  start a temporary Codex App Server for recovery. Codex controls credential refresh and
  storage. API-key sign-ins show unavailable subscription quota. Reset-credit totals
  remain available. Detailed expiry rows appear only when recovery supplies them.
- Cursor reads credentials through system SQLite in read-only mode. Busy databases
  retain stale usage. Keychain fallback and token refresh remain available.
- Each Claude and Codex account keeps its own observation time, errors, and last-good
  readings. Snapshot writes do not block the UI. Cancelled or disabled refreshes cannot
  publish late results for any provider.
- Claude snapshots now use Application Support. Upgrades import newer last-good data
  from the former App Group before cleanup. Existing app settings remain in place.
- Upgrades remove obsolete app-owned statusline snippets, attention hooks, caches,
  widget data, and usage history after required migrations complete. User commands,
  current usage data, settings, credentials, and unrelated files remain. Failed cleanup
  retries at a later launch.
- Visual warning and critical thresholds are now in Appearance settings. An old menu-bar
  forecast setting falls back to the nearest-limit percentage.

### Removed

- Claude Code statusline usage capture, bridge repair, and live-session indicators.
- The desktop widget and App Group settings sync.
- The Usage & Spend window, local Claude and Codex cost estimates, activity heatmap,
  transcript scans, and pricing downloads.
- Usage pace markers, depletion predictions, and the menu-bar forecast option.
- Quota, recovery, predictive, update, and Claude Code attention notifications,
  including the Notifications tab and terminal focus actions.
- Anthropic service-status polling and incident banners.
- Optional Claude web reset offers and their separate web sign-in. Quota reset
  countdowns remain.
- Resident Codex App Server processes and the Codex source-mode picker.
- Cursor credential subprocesses, battery-dependent refresh intervals, and
  network-reconnect refreshes.

### Fixed

- Popover window attachment updates wait until the current SwiftUI view update ends.
- Settings text now describes Claude account selection correctly.

### Security

- The distribution DMG is signed and notarized before Sparkle signs the update archive.

## [2.18] - 2026-09-14

### Added

- Usage & Spend now opens from the popover header. It shows one combined Claude and
  Codex estimate, separate provider sections, daily charts, model totals, and JSON
  export over 7 or 30 days.
- Codex cost estimates support Astra and Sol. Missing prices and incomplete usage are
  marked, and exports preserve unknown costs.
- Optional diagnostic file logging removes sensitive values and records notification and
  widget failures.

### Changed

- Active Claude transcripts reuse verified earlier records, which reduces repeated
  parsing during cost updates.
- Codex reuses its local app-server process between polls to reduce refresh work.
- Optional providers shown only in the popover refresh less often while it is closed.
  The selected main provider keeps its normal polling schedule.

### Fixed

- Cost scans read more of large Claude sessions before reporting an incomplete estimate.
- Attention notifications can focus the correct Herdr pane inside Ghostty.

### Security

- Local statusline and attention-event files restrict access to their owner.

## [2.17] - 2026-09-08

### Fixed

- Codex Pro plan badges now show the correct plan name.
- Codex readings and quota alerts no longer carry over to another login in the same home
  directory.
- Cost and activity totals now update after an atomic transcript replacement, even when
  the file size and modification time stay the same.
- Slow local cost scans no longer delay quota updates. The cost card now shows its own
  scan age and reports incomplete updates.

## [2.16] - 2026-09-05

### Added

- The menu-bar item has a spoken summary for VoiceOver, including the provider, quota
  window, percentage meaning, and paused or stale state.

### Changed

- The extra Claude heading is removed when Codex is the main meter. Each provider card
  already shows its name.
- Releases retain app and widget debug symbols that match the shipped binaries.

### Fixed

- Cursor credential reads no longer crash or launch abandoned commands when startup
  times out.
- Codex process cleanup no longer blocks Swift workers after a timeout or cancellation.
- Valid Codex quotas remain available when optional credit or reset metadata is
  malformed.
- Claude usage backoff survives an app restart and still applies to all accounts.
- Copied transcript history counts once within each account. Unique continuations and
  separate accounts still contribute to cost totals.

## [2.15] - 2026-09-05

### Added

- Codex cards show the available usage-reset count, reset type, and expiry time,
  including when Codex is the secondary provider.

### Changed

- Long reset countdowns include hours, such as `6d 7h`, instead of only whole days.

### Fixed

- Local tests preserve the installed app's polling setting. Tests can no longer pause
  the app and remove the menu-bar percentage.

## [2.14] - 2026-08-28

### Added

- The **Forecast** menu-bar option pairs the nearest quota percentage with its projected
  run-out time.
- When Codex is the main meter, the compact Claude card can expand in place. The card
  shows each account's limits, reset timing, plan, and identity details.

### Changed

- Account cards show when the current usage rate may exhaust quota before reset. The
  forecast replaces the abstract pace gap.

## [2.13.1] - 2026-08-28

### Fixed

- Settings identifies Anthropic rate limits and the automatic retry. A verified Keychain
  connection stays connected during the wait.

## [2.13] - 2026-08-28

### Changed

- Provider cards expand and collapse while the popover follows their size. The header
  stays fixed, and the window stays attached during rapid reversals and display changes.
  Transitions respect **Reduce Motion**.
- Cursor and Codex provider icons support dark mode.

### Fixed

- An expired window from a stale reading shows unknown usage with refresh guidance. It
  no longer claims 100% energy when usage after the reset is unknown.
- An enabled OAuth source stays labeled as not connected until setup completes. Settings
  shows the required **Connect** or manual-entry actions.

## [2.12.1] - 2026-08-22

### Fixed

- Codex usage resets appear again, and current Codex versions no longer make Claude
  Meter quit. Codex removed the `untrusted` approval mode, which made App Server exit at
  startup. Claude Meter then used OAuth without reset details and could receive
  `SIGPIPE` during process initialization. Recovery now uses the supported
  noninteractive mode.

## [2.12] - 2026-08-12

### Changed

- Snapshot reads and writes have bounded waits and fail immediately after a timeout. A
  blocked App Group container cannot freeze polling or add a blocked thread each cycle.
- The Anthropic service-status check runs independently and combines overlapping
  requests. A slow status response cannot delay quota readings.
- macOS memory pressure clears cost and activity caches that the app can rebuild. The
  persisted cost checkpoint stays available for later launches.

### Fixed

- OAuth details have separate freshness state. Failed updates to Opus, scoped limits,
  extra usage, or plan details keep the last values marked stale in the popover and
  Diagnostics. A successful response clears limits that Anthropic no longer reports.
- Codex and Cursor subprocess output has a size limit and drains continuously. Oversized
  or unterminated responses cannot cause unbounded memory use or block the helper.

## [2.11] - 2026-08-12

### Added

- Account cards compare usage with elapsed time in the limit window. Bar cards show a
  pace marker, and both card styles show how far usage is ahead or behind. The marker
  reverses between energy-left and usage views. Pace does not change alert colors or
  thresholds.
- The popover and Settings identify Anthropic rate limits and show a retry countdown,
  such as "retrying in 48m". Rate limits use the quieter style for temporary problems.
  Previously, the cause appeared only in Diagnostics while displayed numbers stopped
  updating.

### Changed

- Opening the popover requests fresh usage. Previously, the popover could show a stale
  reading up to two minutes old. Background checks retain their rate limits.
- Without a live Claude Code session, background checks run every two minutes instead of
  every minute. The interval remains below the stale-data threshold.
- A failed account keeps its previous reading as stale and its failure reason in
  Diagnostics. Healthy accounts continue to update.

### Fixed

- The first successful reading after launch establishes an alert baseline. Existing high
  usage no longer triggers an alert for a threshold crossed while the app was closed.
- Scoped weekly limits use both old and new API fields. Max plan Opus limits remain in
  menu-bar severity, alerts, and the widget during the field migration. Previously
  unknown model limits also appear.
- Keychain safeguards detect both Apple test execution methods. Local tests no longer
  reach live credentials through the previously missed method. The fault affected only
  tests, not released apps.
- A zero retry delay from Anthropic uses the default one-minute wait. The app no longer
  repeats requests while the server continues to reject them.
- A failed refresh during OAuth detail retrieval clears the cached credential. A new
  Claude Code sign-in can then take effect without an app restart.
- Explicit connect, save, and disconnect actions report Keychain write failures.
  Settings can still check credential availability without reading the secret.
- Local cost and activity scans handle rewritten transcripts, incomplete final lines,
  unreadable account roots, and duplicate events across roots. Partial scans are
  identified and do not replace combined results with zero.
- The widget refreshes when data becomes stale, without waiting for its next timeline
  update.
- The widget headline includes the weekly Opus limit. Previously, its session and
  all-models value could show 55% while the Opus row showed 4%.
- Without readings, the popover says it is still warming up. It no longer says that all
  accounts are fresh before data arrives.
- **Copy Sanitized Diagnostics** redacts Codex account display names. A name that
  contains an email address no longer copies that address into the report.
- A Codex **Go** plan is labeled Go instead of Plus.
- The widget's update time advances between redraws.

## [2.10] - 2026-07-27

### Added

- The popover and Settings identify Claude Code sign-in problems and the recovery
  action, usually `claude login`. Previously, the cause appeared only in Diagnostics
  while other sources supplied data. Temporary conditions, such as a locked Keychain,
  use a quieter style.
- Cursor, Codex, and Grok cards collapse. A collapsed card retains the provider, plan,
  percentage, bar, and reset time. Cards remember their expanded state.
- The Codex logo replaces the star icon that could look like a warning.

### Changed

- The popover has a screen-derived height limit and scrolls when its content exceeds
  that limit. Multiple accounts and providers no longer extend below a 13-inch display.
- Provider cards start collapsed after this update. Opening a card restores its details
  and saves the expanded state.
- **Last 7 days** shows the total on one line and still opens the activity heatmap.
- **Settings** and **Quit** move from the footer to the popover header. The footer is
  removed.
- Provider plan badges sit beside provider names. Codex displays the reported plan, so
  Pro 5X and Plus no longer both appear as Pro. The badge remains visible when
  collapsed.
- **Pause** moves to **Settings**, under **Advanced**. The Claude Code version moves to
  **About** and retains its update indicator.
- The refresh button is removed because opening the popover already requests a refresh.

## [2.9] - 2026-07-27

### Changed

- Cursor failures stay on the Cursor card. An expired Cursor token no longer clears the
  Claude menu-bar percentage or makes its status dot gray.
- The widget stops rebuilding its timeline each minute when data is unchanged. Local
  cost data writes less often. Service-status and Cursor sign-in checks use cached
  results between polls.

### Removed

- Unused usage-history recording, which wrote limit samples on each poll without
  displaying them. The app deletes the history file on first launch.

### Fixed

- Connecting an expired Claude Code token no longer leaves the OAuth source unable to
  update. The same fault during an app session is also fixed. An already rejected
  credential still needs `claude login` once. The app then reads the new token.
- Claude account selection tracks actual API activity per session. Multiple windows on
  one account no longer make that account appear continuously active.
- Codex uses direct usage when App Server fails to answer, including on a timeout or an
  incompatible version.
- Missing model cache prices use Anthropic's standard ratios instead of zero. Cost
  estimates no longer omit those charges.
- Rate-limit waits honor `Retry-After` dates as well as delays. Backoff no longer ends
  before the requested deadline.
- Cursor reads credentials through the system Keychain API. The command-line helper that
  could show a blocking permission dialog is removed.

## [2.8.1] - 2026-07-20

### Fixed

- Closing the popover stops its hidden animations. Idle CPU use could reach about 20%
  during a live Claude session or a poll. CPU use now falls to about 0% with the popover
  closed. Session and menu-bar dot pulses update below the full display refresh rate.

## [2.8] - 2026-07-18

### Added

- Attention notification clicks return to the source Ghostty, Terminal, iTerm2, or
  WezTerm tab when possible. Warp and stale routes use an app-focus fallback.
- Optional predictive alerts warn when a fresh forecast from two polls indicates that
  session or weekly energy may run out before reset.
- Codex supports multiple `CODEX_HOME` accounts. Each has its own card, name, polling
  state, and retained reading when another account fails.
- Codex supports App Servers that report windows by limit ID instead of positional
  session and weekly windows.

### Changed

- Reset text uses minutes below one hour, hours below 48 hours, and whole days above
  that threshold, such as "resets in 4 days". It no longer uses calendar dates.
- Codex cards show reset times and omit empty credit balances. The **Trends** panel is
  removed.
- OAuth setup checks Keychain attributes without reading secrets. Claude Code
  credentials are read only after explicit consent.
- One local verification command runs Core tests and unsigned Debug and Release builds.
  Release scripts validate signed artifacts before changing Git state.

### Fixed

- Turn-finished notifications ignore subagent completions until the main Claude turn
  finishes.
- Attention notification clicks bring Ghostty or WezTerm to the front. They never
  relaunch a terminal that has quit. A blocked focus helper cannot stop background work.
- Predictive alerts retain confirmation across source changes and reset-time variation.
  A failed poll clears confirmation. Forecast text uses the same duration format as the
  popover.
- Diagnostics distinguish missing connections from provider errors.
- A macOS Keychain permission prompt during Claude Code connection no longer blocks the
  UI.

## [2.7] - 2026-07-16

### Added

- Cursor cards show the plan and the Auto and Composer/API breakdown. Codex cards show
  the plan, available usage resets, and the nearest expiry when reported.

### Changed

- Cost and activity estimates include Claude subagent transcripts without counting
  copied context twice. One-hour Claude Code cache writes use the correct price.
- The activity scanner caches parsed transcript groups for the app session. It stops a
  scan when the heatmap closes and shows a spinner during the first scan.

### Fixed

- **Launch at Login** explains when macOS approval is required and links to **Login
  Items**.
- Closing Sparkle's update window preserves app focus and Command-Tab access for an open
  Claude Meter Settings window.

## [2.6] - 2026-07-13

### Added

- Grok Build weekly credit usage is an optional **Data** source with its own popover
  card. It reads the `grok` CLI sign-in through an unofficial endpoint that can change
  without notice.
- Every `CLAUDE_CONFIG_DIR` account can show live plan, email, weekly Opus, and
  extra-usage data from its own login. Idle accounts need no open Claude Code session.
  The Claude Code token source must be connected in **Settings**, under **Data**. macOS
  requests Keychain access once per account. **Always Allow** prevents repeated prompts.
- A **Same login** badge identifies config dirs that share one Claude login and quota.
- Plan badges show Max 5x or Max 20x when Anthropic reports the multiplier.

### Fixed

- Codex usage ignores inherited auth overrides, including `CODEX_API_KEY` and
  `OPENAI_BASE_URL`. A terminal launch cannot redirect usage to another account through
  those variables.

## [2.5.1] - 2026-07-06

### Fixed

- Codex percentages match Cursor semantics. The card shows percent used, fills upward,
  and labels weekly usage as used.

## [2.5] - 2026-07-06

### Added

- Codex is an optional **Data** source with its own popover card. Claude retains the
  menu bar, widget, and notifications. Auto mode prefers Codex CLI App Server, with a
  read-only direct OAuth fallback for logins stored in files.

## [2.4] - 2026-06-30

### Added

- The **Trends** card opens usage charts for the 5-hour session, weekly, and weekly Opus
  windows. Each window has a sparkline. The screen shows "building history" until enough
  samples exist.

### Changed

- Local cost history is cached on disk. Launch scans read only new activity instead of
  every transcript.
- Refueled notifications detect limits that reset while Claude Meter was closed.

### Fixed

- **Launch at Login** stays enabled while macOS approval is pending, including after a
  first launch or macOS update.
- A blocked network read cannot freeze later refreshes. The poll loop recovers on the
  next tick.
- Overlapping token refreshes share one request. Wake and network changes no longer
  cause false signed-out states.
- After a Claude Code update, Claude Meter reads the most recently used credentials
  instead of an older Keychain entry.

## [2.3] - 2026-06-30

### Removed

- The claude.ai web-session source and its browser-cookie import. Usage now comes from
  the statusline bridge and Claude Code OAuth. Users of only the web source must run
  Claude Code for statusline data or connect Claude Code OAuth.

## [2.2] - 2026-06-29

### Added

- Native Claude attention notifications report a finished turn or permission request
  across accounts. **Claude Attention** in **Settings**, under **Notifications**, has
  separate controls for each event.
- Account cards estimate when current usage will reach a limit.
- The popover footer identifies an outdated Claude Code version and links to its
  changelog.

### Changed

- Model prices come from models.dev, with corrected built-in fallback rates. The old
  Opus fallback overestimated cost by about three times.

### Fixed

- OAuth refresh prefers current in-memory credentials over stale Keychain data, which
  prevents false signed-out states.

## [2.1] - 2026-06-28

### Added

- **Last 7 days** opens an activity heatmap from local transcripts. The chart groups
  messages by day of week and hour, with color intensity for message count. **Back**
  returns to the main popover.
- **Menu bar shows** in **Appearance** selects the nearest limit by default, the 5-hour
  window, the weekly window, or both, such as `99% 5h · 73% 7d`.
- The popover footer shows the Claude Code version and links to its changelog.

### Changed

- Weekly resets show a calendar date, such as "29 Jun", instead of only a weekday.
- The footer **Add account** button is removed. Account setup remains in **Settings**.

## [2.0] - 2026-06-26

### Added

- **Appearance** settings select rings or bars, energy left or usage, and a pinned
  account or nearest limit for the menu-bar percentage.
- The redesigned UI shows energy left with a combined-health hero and weekly and 5-hour
  activity rings. It includes Fredoka and Nunito fonts and a green bolt icon.
- **Settings**, under **Data**, accepts a display name and plan badge for each account.
  Rate limits remain per account.
- A refueled notification reports when a low account recovers to normal usage or resets.

### Changed

- The menu bar uses a bolt, a status dot for the nearest limit across accounts, and an
  energy-left percentage.
- Settings has a new tab bar for **Data**, **Notifications**, **Advanced**, and
  **About**, with colored threshold sliders and larger account rows.
- The widget uses activity rings and supports light and dark modes.
- Cursor requests use the shared provider transport with redirect protection to prevent
  credential leaks.

### Fixed

- Disabling an account clears its menu-bar pin and removes it from the Appearance
  picker. A single non-default config dir shows its custom name and plan badge.
- The menu-bar percentage and dot use only Claude usage. Cursor retains its own card.
  The menu bar follows the **Menu bar follows** account setting.
- The refreshed-token cache belongs to the selected `auto` or `manual` mode and clears
  on disconnect. Tokens cannot pass between modes within an app session.
- The medium widget shows the weekly Opus limit when available, as the large widget and
  menu-bar severity already do.

## [1.3] - 2026-06-24

### Added

- Window pace badges compare usage with elapsed time. They show **On track**, **Running
  hot**, or **Room to spare**.
- Weekly Opus usage has its own card and contributes to menu-bar severity and
  notifications. For Max plans, this is often the first limit reached.
- The popover shows **Extra usage** spend with a progress bar, including while billing
  is paused.
- The popover shows per-model tokens and estimated costs for seven days from local
  Claude Code transcripts.
- An Anthropic service-status banner distinguishes incidents from expired credentials.
- The popover header shows Max, Pro, Team, or Enterprise when the plan is known.
- **Import from browser** reads a claude.ai session key from Chrome, Brave, Edge, Arc,
  Firefox, or Safari and detects the organization.
- **Check browsers** in Diagnostics reports cookie-import status for each browser
  without secrets.

### Changed

- Background polling stops during display or system sleep and refreshes on wake. Longer
  intervals on battery reduce background work.
- The shared transport blocks redirects to another origin or from HTTPS to HTTP.
  Temporary failures have bounded retries. Keychain reads distinguish a locked store
  from missing credentials.
- claude.ai setup detects the organization from the session key. The **Org ID** field is
  optional.
- OAuth honors HTTP 429 and `Retry-After`, identifies as Claude Code CLI, and accepts
  missing or null usage fields.
- Pause dims the menu-bar icon and hides its percentage.
- Release scripts derive and embed the marketing version and build number. GitHub
  release notes use this changelog.

### Fixed

- OAuth token refresh preserves `subscriptionType`, so the plan badge remains visible.
- The menu-bar percentage uses the limiting window, including weekly Opus, to match
  severity.
- Cookie import matches the exact `claude.ai` host and rejects substrings such as
  `evilclaude.ai`.
- Cost estimates show partial status when scans read only the end of large transcripts.
  Messages without IDs no longer collapse during duplicate removal.
- Implausible `resets_at` values produce unknown pace instead of misleading hot or cold
  states.
- `PowerMonitor` no longer stops polling on `willSleep`. A canceled sleep could
  previously delay refreshes for five minutes.
- Poll and Cursor errors remove sensitive data before display.
- Service-status requests run concurrently with usage and no longer delay the primary
  refresh.
- The widget shows weekly Opus when available. The release script tags the release
  commit instead of the pre-build `HEAD` and reads `TEAM_ID` and `APPLE_ID` from the
  environment.

## [1.2] - 2026-06-24

### Added

- Cursor is an optional usage source alongside Claude.

### Changed

- The core pipeline has corrections for data consistency and polling reliability.

## [1.1] - 2026-06-24

### Added

- Each source has a toggle and active state.
- An app icon and updates to onboarding and Settings.

### Changed

- Usage sources and diagnostics have reliability improvements.

### Fixed

- Usage flicker, idle staleness, and the refresh spinner.

### Removed

- The SQLite history store and floating mini monitor.

## [1.0] - 2026-06-23

### Added

- A Claude Code menu-bar meter with 5-hour and weekly limit windows.
- Local threshold notifications with duplicate suppression.
- A WidgetKit widget that shares snapshots through an App Group.
- Settings and diagnostics views.
- Sparkle automatic updates.

[Unreleased]: https://github.com/jewei/claude-meter/compare/v3.1.3...HEAD
[3.1.3]: https://github.com/jewei/claude-meter/compare/v3.1.2...v3.1.3
[3.1.2]: https://github.com/jewei/claude-meter/compare/v3.1.1...v3.1.2
[3.1.1]: https://github.com/jewei/claude-meter/compare/v3.1...v3.1.1
[3.1]: https://github.com/jewei/claude-meter/compare/v3.0.2...v3.1
[3.0.2]: https://github.com/jewei/claude-meter/compare/v3.0.1...v3.0.2
[3.0.1]: https://github.com/jewei/claude-meter/compare/v3.0...v3.0.1
[3.0]: https://github.com/jewei/claude-meter/compare/v2.18...v3.0
[2.18]: https://github.com/jewei/claude-meter/compare/v2.17...v2.18
[2.17]: https://github.com/jewei/claude-meter/compare/v2.16...v2.17
[2.16]: https://github.com/jewei/claude-meter/compare/v2.15...v2.16
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
