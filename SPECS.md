# Claude Meter specification

This document defines current user-visible behavior and stable system boundaries.
Implementation gotchas and migration history belong in `AGENTS.md`; visual tokens and
component treatment belong in `DESIGN.md`. Removed features are not part of this spec.

## 1. Product contract

Claude Meter is a macOS 14+ menu-bar app for viewing coding quota as energy
remaining. It has no Dock icon (`LSUIElement = YES`) and uses a SwiftUI
`MenuBarExtra` with `.window` style. Claude remains the default main meter for existing
users; users can explicitly select Claude or Codex. Cursor and Grok remain secondary
popover sources.

The app is local-first:

- Provider credentials are read-only except for manually entered Claude OAuth tokens,
  which Claude Meter owns in Keychain.
- Provider secrets are never rendered, logged, or copied into diagnostics.
- The widget reads only the normalized App Group main-meter reading and performs no
  provider I/O.
- Only the explicitly selected main provider affects the hero, first popover section,
  menu-bar indicator, header timestamp, widget, or quota notifications. Missing selected
  data never falls back to another provider.

## 2. Targets and ownership

| Target | Responsibility |
| --- | --- |
| `ClaudeMeter` | AppKit/SwiftUI presentation, settings, polling orchestration, power/network monitors, notifications, Sparkle |
| `ClaudeMeterCore` | Normalized snapshot models, storage, thresholds, notification/reset/pace policy; no UI or provider I/O |
| `ClaudeMeterProviders` | Statusline and hook bridges, OAuth/Keychain/HTTP, transcript scanners, Cursor/Codex/Grok adapters |
| `ClaudeMeterWidgetExtension` | Sandboxed App Group snapshot reader and WidgetKit views |

Dependencies point inward: app and widget depend on Core; the app also depends on
Providers; Providers depends on Core. Provider-specific wire formats do not enter Core.

`AppState` is the main-actor composition root. Each poll captures one immutable
`PollConfiguration`; optional providers publish one coherent `ReadingState` so value,
timestamp, staleness, and error cannot drift apart. `MainMeterReading` is the normalized
Core model shared by app policy, App Group persistence, and the widget; provider wire
models never become presentation or widget contracts.

## 3. Claude data pipeline

`ClaudeMeterPipeline` exposes:

```swift
func poll(now: Date, kind: RefreshKind) async throws -> ParseResult
```

`poll(now:)` is the background convenience. `RefreshKind.interactive` may bypass only
idle API-saving cooldowns; it never bypasses correctness or the shared OAuth 429 gate.

The active pipeline is assembled bottom-up from enabled sources:

1. `StatuslinePipeline`
2. `OAuthPipeline`
3. `CachedSnapshotPipeline` terminal fallback

The statusline tier wins while it has fresh bridge data. If unavailable or stale, OAuth
may run. Every failed tier records a sanitized `SourceAttempt`; fallback does not erase
the reason. Cached data is marked stale and preserves its original successful-fetch time.

Polling normally runs every 60 seconds. It doubles on battery, parks while the display is
asleep, refreshes immediately after wake or network reconnection, and times out a wedged
cycle. Opening the popover requests an interactive refresh. Source-setting rebuilds are
debounced and do not restart an active poll loop.

### 3.1 Statusline bridge

The bridge prepends an idempotent pass-through command to every enabled discovered
Claude config directory. It writes one sanitized session file per account/session under:

```text
~/.claude-meter/sessions/<account-key>/<session-id>.json
```

It preserves the user's existing statusline command, installs with `refreshInterval: 1`,
repairs legacy snippets, and is removed when the source is disabled. Invalid settings in
one config directory do not block the others. Disabling an account filters both discovery
and the session read path.

Fresh payloads are grouped and merged within an account only. The active account is the
one with the latest observed activity-signature change; cold ties use the sticky previous
active key, then payload recency, then key order. File mtime is not activity because an
idle open session rewrites once per second.

The API fallback cooldown is 120 seconds. Interactive popover refresh can bypass this
cooldown, while background polling remains below the 180-second stale threshold. OAuth
429 backoff is never bypassed.

### 3.2 OAuth

OAuth is used only when mode is `auto` or `manual`.

- Auto mode reads Claude Code's legacy or hashed Keychain credential entries after the
  user explicitly confirms Connect. Settings preflight is attributes-only.
- Manual mode stores an app-owned Keychain item and reports save/delete failures.
- Refreshed tokens are cached in memory. Claude Code's Keychain item is never rewritten.
- Refresh failure clears the corresponding in-memory credential cache.
- All usage and refresh requests use the shared cookie-less transport with same-origin
  HTTPS redirect enforcement.
- The process-wide 429 gate is shared by polling, verification, and enrichment and honors
  positive `Retry-After` delta or HTTP-date values.

The usage response maps `five_hour`, `seven_day`, `seven_day_opus`, dynamic scoped weekly
limits, `extra_usage`, and plan metadata. Flat scoped fields win over equivalent entries
in `limits[]`; unknown/null windows degrade without failing the whole response. Extra
usage minor units are scaled by the response's decimal places.

Statusline does not provide Opus, scoped limits, extra usage, or plan. OAuth enrichment
replaces those fields without touching fresher statusline session/weekly windows. A
successful enrichment is a complete observation: absent optional fields clear older
values. An unavailable or failed fetch produces no observation and keeps the cached one.
The auxiliary fetch has its own coherent reading lifecycle (`current` / `stale` /
`failed`) because a fresh statusline result bypasses the main OAuth fallback trail. A
failed refresh preserves the last successful observation timestamp, marks only the
OAuth details stale in the popover, and records its typed reason in Diagnostics.

Multi-account OAuth runs only in auto mode and never refreshes secondary-account tokens.
It reads each config directory's namespaced credential plus local account identity, fetches
at most every five minutes, and merges fill-only-missing account data. Each reading keeps
its actual fetch timestamp. Failures remain per-account state instead of masquerading as
fresh absence. The active account keeps the single-slot refresh path.

### 3.3 Snapshot and staleness

The App Group suite is `group.com.jewei.claudemeter`. `SnapshotStore` atomically writes Claude's `current.json`, the selected provider's
normalized `main-meter.json`, and sanitized last-error data. Provider/account/source
changes bump a mirrored selection revision; the widget rejects a file from an older
revision or a mismatched provider/exact pin. App startup migrates a legacy Application
Support snapshot into the App Group when needed. The widget never falls back outside the
App Group.

`lastSuccessfulPollAt` changes only after a usable successful poll. Data is stale after
180 seconds unless explicitly marked stale earlier. Claude notices use Claude staleness;
an optional provider's stale state cannot make the Claude card stale.

Top-level limit fields mirror the active account for backward compatibility. `accounts`
is nil only for the single default `claude` account. A lone non-default account remains a
one-element array so per-account overrides have a stable key.

Expired rolling windows resolve to 0% used and no reset date. Consumers must call
`LimitWindow.resolved(asOf:)` before display or policy evaluation.

## 4. Local cost and activity

Cost and activity scan every enabled discovered config directory's `projects/`, including
top-level session journals and direct `subagents/*.jsonl`; context-fork replays and deeper
workflow journals are excluded. One unreadable root or file marks the result partial and
does not erase readable data.

Cost scans assistant usage chunks for the last seven days. Within each file, chunks with
the same message/request identity are combined globally by maximum token fields. Cache
creation tier breakdown wins over the legacy total; legacy-only writes count as 5-minute
cache writes. Large files are tail-read and reported partial. Incremental reuse is allowed
only when file identity/prefix continuity proves an append; incomplete trailing lines are
revisited after append. Model output is deterministically ordered.

Activity is loaded on demand from the cost card. It reports a 7×24 local-time grid over the
last 30 days, Monday at index zero, deduping message identity within each file. Its total is
derived from the normalized grid. Cache identity includes timezone.

Both scanners use bounded, constant-time LRU caches. Cost cache is persisted and
rate-limited; activity cache is in memory only. On macOS memory-pressure warnings, the
app drops both rebuildable in-memory caches and asks malloc to release free pages off-main.
The last flushed cost-cache file remains intact, but the current process repopulates only
files touched by later scans instead of immediately reloading the whole disk cache.

## 5. Optional providers

### 5.1 Cursor

Cursor is opt-in. Credentials are detected from Cursor's local state database with a
Keychain fallback through the fail-closed gateway. Detection is memoized by database file
identity. Access/refresh caches are bound to the detected account credential identity and
are cleared immediately on account rotation. Refresh stays in memory. Cursor errors and
staleness appear only on its popover/settings/diagnostics surfaces.

### 5.2 Codex

Codex is opt-in and supports one implicit `CODEX_HOME` plus explicitly configured homes.
Each home has its own subprocess/provider state and display name. Provider subprocesses
strip environment credential overrides. App-server request/response dispatch is actor
isolated so overlapping requests cannot consume one another's messages. Positional and
keyed rate-limit windows independently fill missing session/weekly buckets. App-server
account metadata retains the reported authentication mode. Auto-mode failures preserve
both the app-server and direct-OAuth reasons for diagnostics.

Last-good readings are persisted per resolved Codex home, without account email, and are
restored on launch. A failed refresh retains that reading and records the attempt error/time
separately from the last-success time; observation staleness remains age-based. Healthy
accounts continue updating when another account fails. Main-meter normalization classifies
windows by reported duration (up to 24 hours is short/session; longer is weekly), falling back
to primary/secondary position only when duration is absent.

### 5.3 Grok

Grok is opt-in and reads the Grok CLI auth file without writing or refreshing it. Candidate
entries are preference-ordered, then the first valid usable token is selected. Expired
credentials require opening Grok. Usage comes from the CLI billing endpoint and is shown
only in its own popover/settings/diagnostics surfaces.

## 6. Presentation

Canonical data stores percent used. Presentation defaults to energy remaining:

```text
percentLeft = clamp(100 - resolved.percentUsed, 0...100)
```

Rings and bars deplete in `left` mode and fill in `used` mode across Claude, Codex,
Cursor, and Grok usage cards.
Severity always uses percent used and the configured warning/critical thresholds;
progression mode does not change policy. Unknown values render neutral placeholders and
never use an empty/tapped-out phrase.

Pace presentation compares percent used with percent of the fixed rolling window elapsed.
Bar cards show a neutral expected-position marker plus compact pace text; the marker mirrors
between `used` and `left` progression modes. Ring cards show text only for the primary session
and weekly rings while retaining reset timing. Pace never affects severity or color. If the
reset time is absent, expired, or outside the window span, pace presentation disappears and
the bar falls back to its energy phrase.

The menu-bar dot uses the highest severity from the selected main provider across all
binding windows of the pinned account, or all of that provider's accounts when unpinned.
Its number follows `menuBarWindow`: nearest, short/session, long/weekly, or both. A
single-window number may intentionally differ from the all-window dot. Selecting a provider
or account with no reading produces an explicit unavailable/error state, never fallback.

The popover is 360 points wide with a screen-derived scrolling height. Header controls are
Settings and Quit; opening performs refresh, so there is no redundant refresh button.
The selected provider owns the hero and first account section. An exact account pin wins;
otherwise the account nearest its limit owns every primary surface. The other eligible
provider remains visible below as one compact secondary summary. When Claude is secondary,
the summary shows the nearest account's plan when known and expands in place to reveal each
account's session, weekly, Opus/scoped windows, reset timing, and known identity metadata.
Primary Claude account cards are always expanded. Primary Codex, Cursor, and Grok account cards
remember their expanded state.
The header timestamp belongs only to the selected reading. The last-seven-days cost card
opens the activity heatmap. There is no footer or Add Account button.

First-run onboarding pauses polling and directs the user to Settings. Existing users skip
onboarding when a snapshot, attributes-only OAuth credential presence, Cursor state, an
enabled Codex home with `auth.json`/`config.toml`, or the Claude Meter data directory exists.
Rendering onboarding never reads credential contents or secret Keychain data.

All reset/refill copy uses Core `ResetPhrase`: minutes below one hour, hours below 48 hours,
and days from 48 hours. Surfaces never introduce their own date/weekday formatter.

## 7. Settings

Settings uses a custom tab bar with Appearance, Data, Notifications, Advanced, and About.
Display settings are mirrored from standard defaults into the App Group; removing a source
value removes the mirrored value so defaults cannot become stale.

| Key | Domain value | Default |
| --- | --- | --- |
| `cardStyle` | `rings`, `bars` | `rings` |
| `progressionMode` | `left`, `used` | `left` |
| `mainMeterProvider` | `claude`, `codex` | `claude` |
| `menuBarAccount` | nearest or Claude account key | nearest |
| `codexMainMeterAccount` | nearest or Codex home id | nearest |
| `menuBarWindow` | `nearest`, `5h`, `7d`, `both` | `nearest` |
| warning threshold | percent used | 80 |
| critical threshold | percent used | 95 |
| stale interval | seconds | 180 |

Account names/plans are user overrides. Display precedence is name override then friendly
config label; plan override then active-account OAuth plan then per-account OAuth plan.
Configured paths are canonicalized and account disabling never removes the default account.

## 8. Notifications and attention hooks

Quota notifications process only fresh observations from the selected main provider.
Threshold events are typed by scope and level, and dedup by provider, account, scope,
level, and reset cycle. A provider/account switch establishes a new baseline and never
compares unrelated quota. Recovery compares raw prior severity so a rolling-window reset
can emit “refueled.” Attention hooks remain Claude Code-specific and independent of the
main-meter selection.

Predictive depletion is opt-in. It requires two consecutive fresh qualifying observations
for the same account/scope/reset cycle and normal current severity. Small reset-time jitter
is tolerated by the documented five-minute cycle bucket. Failed, stale, timed-out, or
nonqualifying polls reset the qualification streak.

Attention hooks support main-agent `Stop`, permission `Notification`, and limit/billing
`StopFailure`. Subagent `Stop` is consumed without notifying. Hook installation is
idempotent and pass-through. Click routing activates the app first, then best-effort focuses
an already-running terminal; it never launches a terminal and bounds subprocess waits.

## 9. Widget

The widget supports small, medium, and large families. It loads `main-meter.json` through
Core's provider/account/revision-validating `MainMeterPublication` seam and shows
depleting rings for the selected Claude or Codex account, optional Opus rows where space
allows, provider/account identity, staleness, and a neutral no-data state. Timeline refresh
is the earliest of the next binding reset, the stale deadline, or 15 minutes. Provider,
account, and progression changes request a WidgetKit timeline reload. Widget fonts and
color helpers intentionally remain target-local.

## 10. Networking, Keychain, and diagnostics

Every provider request uses `ProviderHTTPClient.shared` or an injected `HTTPTransport`.
The production session is ephemeral, cookie-less, ten-second timeout, and refuses redirects
that change HTTPS origin. Transient retry applies only to idempotent methods and bounded,
finite delays; OAuth handles 429 separately.

All Security.framework calls pass through `KeychainGateway`, which disables interaction and
fails closed in test processes unless live Keychain testing is explicitly enabled. Candidate
selection is deterministic on equal timestamps. Secret reads occur only after explicit user
action or during an enabled provider poll.

All errors are sanitized at UI and persistence boundaries. Sanitization redacts emails,
home paths, UUIDs, bearer/JWT/provider tokens, session keys, and labeled sensitive fields.

## 11. Verification and maintenance

The authoritative local/CI gate is:

```bash
./scripts/verify-local.sh
```

It runs strict Swift formatting checks, all Core/Provider package tests, and unsigned Debug
and Release app/widget builds. CI invokes this script directly. Sparkle is exactly pinned by
the Xcode project and committed workspace resolution.

Release publishing must make the signed GitHub asset available before pushing the new
`appcast.xml` to `main`; users must never observe a feed pointing at a missing artifact.

Tests should be hermetic: temporary directories are unique and cleaned up, wall clocks and
shared defaults are injectable where policy depends on them, and live user Keychain or
Application Support data is never read by default.
