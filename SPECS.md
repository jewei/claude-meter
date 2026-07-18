# Claude Meter Current Specification

This file is the rebuild spec for the current Claude Meter app. It captures the
features and architecture that are still part of the product, plus the legacy
features that were intentionally discarded. A new implementation should be able
to start from this document without relying on the older `SPECS.md`.

---

## 1. Product shape

Claude Meter is a macOS menu bar app that shows Claude usage-limit percentages.

- It is a menu-bar-only app (`LSUIElement = YES`), with no Dock icon.
- The menu bar item uses `MenuBarExtra` with `.window` style.
- The main UI is a compact SwiftUI popover.
- A WidgetKit extension displays the same latest snapshot from the App Group.
- The core parsing/pipeline/storage code lives in `ClaudeMeterCore`, a Swift
  package with no AppKit or SwiftUI dependencies.

The app intentionally focuses on:

1. Current session usage.
2. Current week usage across all models.
3. Stale/error state.
4. Optional notifications when usage crosses configured thresholds.

It no longer includes history, charts, mini monitors, stats-cache setup, or CLI
status parsing in the production path.

---

## 2. Current user-facing behavior

### 2.1 Global active/inactive state

Claude Meter has a global state:

- **Active**: polling is allowed.
- **Inactive / Paused**: no usage data is fetched.

Rules:

- Default is inactive. `UserDefaults.bool(forKey:)` naturally returns `false`
  for a missing key, so first launch starts paused.
- First-run onboarding explicitly calls `AppState.setActive(false)`.
- Manual refresh is disabled/no-op while inactive.
- Scheduled polling is disabled while inactive.
- If a poll is already in flight and the user pauses, the late result is
  ignored (poll guards on `pipelineGeneration` and `canPoll` after each await).
- The menu bar icon is dimmed while inactive:
  - secondary foreground style
  - `opacity(0.5)`
- The popover **header** has an Active/Paused **toggle switch** (not a footer
  button). Flipping it calls `AppState.setActive(_:)`.
- If paused with a cached snapshot, the popover still shows the last known usage
  cards (there is no separate "paused" banner over them).
- If paused without a cached snapshot, the popover shows a paused empty state:
  "Paused" + "Turn on the toggle above to start fetching usage data."

Persisted key:

| Key        | Type | Default | Meaning                             |
| ---------- | ---- | ------- | ----------------------------------- |
| `isActive` | Bool | `false` | Global active/inactive polling gate |

### 2.2 First-run onboarding

On first run (`hasCompletedOnboarding == false`):

- The popover's main content shows an inline welcome screen (not a sheet): the
  app logo, "Welcome to Claude Meter", a short instruction to configure data
  sources, and a chevron pointing at the footer.
- While onboarding, `AppState.setActive(false)` is called so the app starts
  paused.
- There are no dedicated "Open Settings"/"Continue" buttons in the welcome
  content. The footer **Settings (gear)** button completes onboarding —
  `openSettingsAndCompleteOnboarding()` sets `hasCompletedOnboarding = true` and
  opens Settings.
- `skipOnboardingForExistingUsers()` auto-completes onboarding when a snapshot,
  claude.ai/OAuth credentials, or the `~/.claude-meter` directory already exist,
  so upgrading users don't see the welcome screen.

Rendering the welcome copy must not probe credentials; the keychain/directory
checks happen only in the skip decision on appear.

Persisted key:

| Key                      | Type | Default | Meaning                                         |
| ------------------------ | ---- | ------- | ----------------------------------------------- |
| `hasCompletedOnboarding` | Bool | `false` | Whether first-run onboarding has been dismissed |

### 2.3 Polling cadence

Refresh cadence is fixed:

- Scheduled app polling: once per minute.
- Statusline stale threshold: 60 seconds.
- API fallback cooldown after stale statusline: 60 seconds.

There are no user-facing polling interval sliders.

Polling starts only if:

1. Global `isActive == true`, and
2. At least one data source toggle is enabled.

If no source toggle is enabled:

- No scheduled polling runs.
- Manual refresh is disabled/no-op.
- Popover shows "No data methods enabled".

### 2.4 Data source toggles and priority

Settings -> Data shows the three data sources in priority order. Each source has
its own toggle.

| Priority | Key                       | Default | Source                        |
| -------- | ------------------------- | ------- | ----------------------------- |
| 1        | `statuslineSourceEnabled` | `true`  | Claude Code statusline bridge |
| 2        | `oauthSourceEnabled`      | `true`  | Claude Code OAuth usage API   |
| 3        | `claudeAISourceEnabled`   | `true`  | claude.ai session usage API   |

A fourth source is available outside the Claude fallback chain:

| Key                    | Default | Source                                      |
| ---------------------- | ------- | ------------------------------------------- |
| `cursorSourceEnabled`  | `false` | Cursor billing-period usage (unofficial API) |

Cursor is polled in parallel when enabled; it does not participate in the
Claude `StatuslinePipeline -> OAuthPipeline -> …` chain.

The pipeline must preserve this order while skipping disabled methods. For
example:

- Statusline on, OAuth on, claude.ai on:
  `StatuslinePipeline -> OAuthPipeline -> ClaudeAIPipeline -> CachedSnapshotPipeline`
- Statusline off, OAuth on, claude.ai on:
  `OAuthPipeline -> ClaudeAIPipeline -> CachedSnapshotPipeline`
- Statusline on, OAuth off, claude.ai on:
  `StatuslinePipeline -> ClaudeAIPipeline -> CachedSnapshotPipeline`
- Only claude.ai on:
  `ClaudeAIPipeline -> CachedSnapshotPipeline`
- All off:
  no polling; do not call `CachedSnapshotPipeline` on a timer.

Connecting a method may turn its toggle on:

- Saving/using OAuth credentials sets `oauthSourceEnabled = true`.
- Saving claude.ai credentials sets `claudeAISourceEnabled = true`.

### 2.5 Menu bar label

The menu bar label is an **energy bolt + a nearest-limit status dot**:

- `bolt.fill` glyph.
- A status dot (top-right) reflecting the **highest severity across all accounts**
  (`AppState.severity` scans every `snapshot.accounts` entry, not just the active
  one — rate limits are per-account): green (normal), orange (warning), red
  (critical, pulsing), gray (stale). Over-limit shows a small "0" badge.
- A compact **energy-left %** — the nearest limit, i.e. `100 − max percentUsed`
  across the session / weekly / Opus windows of all accounts (plus Cursor when
  enabled).
- Loading: spinning `arrow.clockwise`. Fatal/no-snapshot error:
  `bolt.trianglebadge.exclamationmark`.

Reduce Motion disables the critical pulse. Inactive styling: secondary
foreground, 55% opacity, dot and number hidden.

### 2.6 Popover

The popover is **~360pt wide**, cream-surfaced (adaptive light/dark), and uses the
playful "energy" design system (see DESIGN.md). Everything is framed as **energy
remaining** ("% left" = `100 − percentUsed`); rings and bars *deplete*. Severity
and the user thresholds still drive colors — the UI just shows the inverse.

Anatomy (top to bottom):

- **Header**: bolt app-icon tile + "Claude Meter" + "Updated …" + a circular
  refresh button.
- **Hero card** (combined health): a mascot emoji + a state-driven headline
  ("You're cruising" / "Pace yourself" / "Almost tapped out" / "Take a breather")
  and a subline that flags the lowest account. Colored by the active account's
  energy band.
- **ACCOUNTS** section: one **activity-ring card per account** (active first).
  Each card has two concentric depleting rings (outer = weekly, inner = 5-hour),
  the avatar letter, the account name (user-set display name or config-dir label),
  an optional plan badge, and `5-hr / week / opus` rows with % left + reset.
- Extra-usage, last-7-days cost, Cursor, and Codex cards follow when present (restyled).
  The Cursor card shows the current plan and the API's optional `Auto + Composer`
  and `API` usage percentages below the authoritative total percentage.
  Codex renders one card per configured `CODEX_HOME`; the implicit default home
  stays first and Settings can rename accounts or add and remove explicit homes.
  Cards omit account email. Each card shows its
  normalized plan tier plus the authoritative available rate-limit-reset count
  and nearest known reset-credit expiry. Accounts poll independently, so one
  failed login keeps its last reading without hiding healthy accounts.
  The **last-7-days cost card is tappable** — it flips the popover body to an
  **activity heatmap** (a GitHub-style 7×24 punchcard, Mon–Sun × hour-of-day,
  shaded by message volume) with a **Back** button. The heatmap is scanned on
  demand from local transcripts (`ActivityScanner`, last 30 days, local time).
- **Footer**: the Claude Code version (`snapshot.source.cliVersion`, when present)
  as a link to the changelog on the left, then pause/resume, settings, and quit
  (chunky square buttons) on the right. Add-account lives in Settings (the gear).

`accountModels` builds the unified `[AccountCardModel]` (uses `snapshot.accounts`
when present, else a single synthesized card from the top-level snapshot).

Main content states (selected in order by `mainContent`): onboarding, paused
(shows cards if data present), no-sources, loading, usage (with degraded/stale
notices), error (session-expired offers Settings), and setup/no-data fallback.
Each non-data state reuses the cream shell with a mascot emoji + line.

### 2.7 Settings

Settings window:

- Hosted in the `Settings` scene; cream background and the chunky-card design
  system throughout.
- A **custom bold tab bar** (icon over a bold label; selected tab in a green pill)
  replaces the native `TabView` chrome. Window title "Claude Meter — Settings" and
  floating window level via `SettingsWindowAccessor` (LSUIElement menu bar app).
- Fixed size: width 560, height 500.

Tabs: **Data** (`cylinder.split.1x2`), **Appearance** (`paintpalette.fill`),
**Notifications** (`bell`), **Advanced** (`slider.horizontal.3`), **About**
(`info.circle`). Window is 560×640. The global **Active** toggle is not in
Settings — pause/resume lives in the popover footer.

#### Data tab

Scrolling layout with a "Data Sources" header and subtitle noting that multiple
sources can be enabled for redundancy. Three data-source cards
(`DataSourceCard`), each with an icon, title, subtitle, and an enable switch.
Toggling any source calls `rebuildPipeline()`.

1. **Statusline Bridge** — icon `terminal`, green tint
   - Key: `statuslineSourceEnabled` (default true). Subtitle: "Checks your
     statusline once per minute."
   - Lists discovered accounts as **roomy sub-cards**: an avatar tile, an editable
     **display name** (`accountNames`), a monospace config-dir path chip, a **plan
     picker** (`accountPlans`: Free/Pro/Max/Team — OAuth is single-slot so plan is
     user-set), and a mini on/off toggle (`claude` is never disablable). Plus a
     chunky "Add config directory…" button and a short `CLAUDE_CONFIG_DIR` helper.
     Toggle/path changes call `scheduleRebuildPipeline()`; name/plan are read back
     by the popover each render.
2. **Claude Code OAuth** — icon `key.fill`, yellow
   - Key: `oauthSourceEnabled` (default true).
   - Subtitle: "Use OAuth credentials from Keychain."
   - Embeds a stateful connection section (`OAuthConnectionSection`) driven by
     `oauthMode` (`""` | `auto` | `manual`). States: idle, prompt (auto /
     no-auto), manual entry, verifying, connected (auto / manual), error.
     - **Auto**: "Connect" uses the Claude Code credentials already in the
       Keychain; "Enter manually" switches to token entry.
     - **Manual**: access-token and refresh-token fields with show/hide toggles;
       "Save and connect" stores them in the app-owned Keychain entry.
     - On connect, verifies via `OAuthPipeline.verify` and shows
       "Session X% · Week Y%", then rebuilds the pipeline and refreshes.
     - Connected state offers "Re-authenticate" and "Disconnect" (manual
       disconnect deletes the app-owned Keychain entry and clears `oauthMode`).
   - When the source toggle is off, the section is hidden.
3. **Claude.ai Session** — icon `globe`, blue
   - Key: `claudeAISourceEnabled` (default true).
   - Subtitle: "Use web session usage API."
   - **Not connected**: session-key field (show/hide) + Org ID field, "Connect".
     Validates session-key format and org-ID UUID via `CredentialValidator`;
     help text points to browser DevTools → Cookies → claude.ai.
   - **Connected**: "Test connection" (shows "Session X% · Week Y%") and
     "Disconnect".
   - Surfaces a "Session expired. Please login again." banner when an error
     mentions session expiry / session key / 401.

No poll-interval or staleness sliders appear in Settings; those are internal
constants / `AppGroupConfig` values.

#### Appearance tab

Four chunky-card controls (all synced to the App Group; the widget reloads on a
progression change):

- **Account cards** — `cardStyle`: "rings" (default activity rings) or "bars"
  (Frame-A energy bars). Popover only; the widget stays rings.
- **Show** — `progressionMode`: "left" (energy remaining, default; rings/bars
  *deplete*, number is % left) or "used" (fills; number is % used). Applies to the
  popover, menu bar, and widget.
- **Menu bar follows** — `menuBarAccount`: "Nearest limit" (default) or a specific
  account, pinning the menu-bar % + dot to it (`AppState.menuBarLimitSets`).
- **Menu bar shows** — `menuBarWindow`: which window the menu-bar number reflects —
  `nearest` (default; lowest energy-left across all windows/accounts), `5h`, `7d`,
  or `both` (`99% 5h · 73% 7d`). For `5h`/`7d`/`both` the value comes from the
  active (or pinned) account via `AppState.menuBarActiveLimits`, with a suffix
  label; `nearest` keeps the unsuffixed nearest-limit behavior. The status dot
  color still keys off severity across *all* windows, so a single-window number
  can legitimately differ from the dot.

#### Notifications tab

Chunky-card layout.

- **Enable notifications** card (`enableNotifications`, default true) with a helper
  box: one alert per threshold per reset window. `predictiveNotificationsEnabled`
  defaults off; when enabled, a depletion forecast must qualify on two consecutive
  fresh polls for the same account/window/reset cycle before it alerts.
- **Claude Attention** card with independent Stop / Notification / StopFailure
  toggles. Clicking an alert returns to the originating terminal when a captured
  route is still live; macOS may request Automation access on first use.
- **Severity Thresholds** card with two **color-coded `ColorSlider`s** (orange
  Warning, red Critical) — each a dot + label + tinted percentage pill + a
  ring-thumb slider:
  - Warning: range 50–90, step 5, default 80 (`warningThresholdPercent`).
  - Critical: range 60–100, step 5, default 95 (`criticalThresholdPercent`).
  - Clamp: if critical ≤ warning, critical bumps to `min(100, warning + 5)`.
  - Changes sync to the App Group (`AppGroupConfig.syncDisplaySettings`) and apply
    to both meter colors and notifications.

Thresholds are **% used** (the engine of truth); the popover shows the inverse as
energy left.

#### Advanced tab

Three chunky-card sections:

- **App** — "Launch at login" (`launchAtLogin`, purple power tile), via
  `SMAppService.mainApp`, synced from system status on appear.
- **Updates** — "Check for updates automatically" (`SUEnableAutomaticChecks`, blue
  tile) with a dynamic status ("Up to date · v&lt;x&gt; ✓" green, or "Update
  available" amber when `appState.updateAvailable`), a chunky "Check for updates…"
  button, and "Last checked …" (Sparkle's `SULastCheckTime`).
- **Diagnostics** — orange waveform tile + an "Open Diagnostics… ›" button
  presenting `DiagnosticsView`.

#### About tab

A centered chunky card: the **green-bolt mark** (drawn in SwiftUI with a green
glow — the app icon's identity), "Claude Meter" in Fredoka, a green "VERSION
&lt;x&gt;" pill (`CFBundleShortVersionString`), a fit-width "View on GitHub"
button, a divider, "© JEWEI MAK", and the trademark disclaimer.

---

## 3. Architecture

### 3.1 Targets/modules

| Component | Target/module                   | Responsibilities                                                                                                |
| --------- | ------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Main app  | `ClaudeMeter` app target        | SwiftUI UI, menu bar, settings, keychain wrapper for claude.ai, Sparkle integration, polling orchestration      |
| Core      | `ClaudeMeterCore` Swift package | Models, snapshot store, pipelines, statusline bridge, OAuth keychain, API clients, parsing, notification policy |
| Widget    | `ClaudeMeterWidgetExtension`    | WidgetKit views reading latest snapshot from App Group only                                                     |

The app's playful design system lives in `PlayfulTheme.swift` (palette, fonts,
energy semantics, chunky-3D modifiers) and `PlayfulComponents.swift` (activity
rings, account ring card, hero, `ColorSlider`). Real **Fredoka + Nunito** are
bundled under `ClaudeMeter/Fonts/` and registered via `ATSApplicationFontsPath`
in both the app and widget targets.

### 3.2 App state

`AppState` is `@MainActor final class AppState: ObservableObject`.

Published state:

- `snapshot: ClaudeUsageSnapshot?`
- `lastPollResult: ParseResult?`
- `isLoading: Bool`
- `lastError: String?`
- `lastPolledAt: Date?`
- `isPopoverOpen: Bool`
- `updateAvailable: Bool`
- `isActive: Bool`
- `hasEnabledDataSource: Bool`

Owned services:

- `pipeline: any ClaudeMeterPipeline`
- `store: SnapshotStore`
- `notificationEngine: NotificationEngine`
- Sparkle updater controller/delegate
- polling `Task`

Important rules:

- `lastPolledAt` advances only on successful snapshot updates.
- Failed polls set `lastError` but do not advance `lastPolledAt`.
- `rebuildPipeline()`:
  - increments generation
  - refreshes `hasEnabledDataSource`
  - rebuilds pipeline from current source toggles
  - restarts polling only if polling is allowed
- Poll results are ignored if pipeline generation changed or if polling became
  disallowed while the poll was in flight.

### 3.3 Pipeline protocol

Core protocol:

```swift
public protocol ClaudeMeterPipeline: Sendable {
    func poll(now: Date) async throws -> ParseResult
}
```

`AppState.pipeline` is typed as `any ClaudeMeterPipeline`.

Production pipeline factory builds from bottom to top:

1. Start with `CachedSnapshotPipeline`.
2. Wrap with `ClaudeAIPipeline` if `claudeAISourceEnabled` and credentials
   exist.
3. Wrap with `OAuthPipeline` if `oauthSourceEnabled`.
4. Wrap with `StatuslinePipeline` if `statuslineSourceEnabled`.

Disabled layers are skipped.

### 3.4 Snapshot storage

`SnapshotStore` writes JSON files:

- `current.json`
- `last-error.json`

Factories:

- `SnapshotStore.appGroup(suiteName:)`
- `SnapshotStore.applicationSupport()`
- `SnapshotStore(directory:)`

Main app store selection:

1. Prefer App Group container.
2. If available, migrate latest snapshot from legacy Application Support into
   App Group.
3. Fall back to Application Support.
4. Last fallback: temporary directory.

Widget store selection:

- App Group only.
- No Application Support fallback in the widget.

App Group:

- Suite/container: `group.com.jewei.claudemeter`

### 3.5 Snapshot model

Primary model: `ClaudeUsageSnapshot`.

Important fields:

- `schemaVersion`
- `parserVersion`
- `createdAt`
- `lastSuccessfulPollAt`
- `source`
- `account`
- `session`
- `limits`
- `models`
- `mcp`
- `settingSources`
- `state`

The current UI uses primarily:

- `limits.currentSession`
- `limits.currentWeekAllModels`
- `state.severity`
- `state.isStale`
- `lastSuccessfulPollAt`
- `parserVersion`
- `source.command` for diagnostics

`LimitWindow`:

- `percentUsed: Double?`
- `resetsAt: Date?`
- `rawResetText: String?`
- `rawValueText: String?`

Display rules:

- Clamp display percent to 0...100.
- If raw percent is greater than 100, display `100%+`.
- Whole percentages display without decimal; otherwise one decimal.
- `resolved(asOf:)` — a window whose `resetsAt` has passed is treated as a reset
  rolling window: `percentUsed` becomes 0 and `resetsAt` is dropped. Applied in
  `StatuslinePipeline.displayWindow` (so statusline snapshots are stored
  pre-resolved, feeding severity + notifications) and at the view layer
  (`UsageCardView`, widget `WindowRow`).

Severity:

- warning default: 80%.
- critical default: 95%.
- `< warning` => normal.
- `warning ..< critical` => warning.
- `critical ... 100` => critical.
- `> 100` => overLimit.
- nil/invalid => unknown.

---

## 4. Data sources

### 4.1 Priority 1: Statusline bridge

Pipeline: `StatuslinePipeline`.

Multiple accounts (`CLAUDE_CONFIG_DIR`):

- Users may run several Claude accounts, each with its own config dir
  (`~/.claude`, `~/.claude-work`, …). Rate limits are **per account**, so the
  meter keeps them separate and never blends them.
- `ConfigDirDiscovery` discovers config dirs (`~/.claude*` holding `settings.json`
  or `projects/`, plus user-added paths, minus disabled ones; `~/.claude` always
  included) and derives a canonical **account key** kept byte-identical to the
  bridge snippet.

Source files (one per session, per account):

- `~/.claude-meter/sessions/<accountKey>/<session_id>.json`
- Legacy `~/.claude-meter/sessions/<session_id>.json` (flat) and
  `~/.claude-meter/statusline.json` (single file) are still read during the
  migration window, bucketed under the default `claude` account, and age out by
  the freshness filter.

Bridge install:

- Installed only when polling is allowed and statusline source is enabled.
- `StatuslineBridge.install(configDirs:)` installs into **each discovered config
  dir's** `settings.json`; idempotent and self-healing. A dir with invalid-JSON
  settings is skipped (its error surfaced after) without blocking the others.
- It rebuilds `statusLine.command` to exactly `<current snippet> | <user command>`:
  - It first strips **every** known bridge snippet (current + `legacyBridgeSnippets`,
    which includes the pre-account snippet) via `strippedOfAnyBridge`, which loops
    to collapse accumulated duplicates and migrate old installs.
  - The snippet derives the **account key** from `$CLAUDE_CONFIG_DIR` (basename,
    leading dot stripped, sanitized with `LC_ALL=C tr` for byte-parity with the
    Swift key), extracts the payload's `session_id` (via `sed` on the compact
    JSON), and atomically writes stdin to `sessions/<accountKey>/<session_id>.json`
    (`default.json` when the id is empty/missing, `claude` when the key is empty).
  - Pipe order matters: the bridge must capture stdin before the user's command,
    and it `printf`s stdin through unchanged so the user's statusline still
    renders.
- If no existing command exists, command is `bridge > /dev/null`.
- It sets `statusLine.refreshInterval = 1`.
- It must not overwrite invalid existing Claude settings:
  - Missing settings file is treated as `{}`.
  - Invalid JSON throws.
  - Non-object JSON root throws.
- Install failures are sanitized and written to `last-error.json`.

Freshness and merge:

- A payload is fresh when its file was modified within 60 seconds (so an
  idle-but-closed session's file ages out; an idle-but-open session keeps a
  fresh file but stale numbers — see below).
- `StatuslineBridge.readDataGrouped(maxAge:)` buckets **every** fresh session file
  by account and runs `mergePayloads` **within each account only** (never across):
  it picks the freshest reading per window — latest `resets_at` for the five-hour
  and weekly windows. This prevents the meter flipping between a single account's
  concurrent sessions while keeping accounts independent.
- `StatuslinePipeline` mirrors the **active account** (the one whose activity
  signature — cost/usage fields that move only on real API calls — changed most
  recently; seeded from the last snapshot on rebuild) into the snapshot's
  top-level fields, and lists the rest in `ClaudeUsageSnapshot.accounts`.
- Fresh statusline data is accepted only when it includes at least one rate-limit
  window: `five_hour` or `seven_day`.
- If fresh and accepted, no lower-priority source is called.
- If stale/missing/unusable, fall through to the next enabled source.
- API fallback through the statusline layer is rate-limited to once per minute.

Rolling-window expiry:

- Claude's windows are **rolling**. An open-but-idle session keeps re-emitting its
  last snapshot every second, so file mtime is not a data-freshness signal —
  `resets_at` is. A window whose `resets_at` has passed is expired and reads 0%.
- `LimitWindow.resolved(asOf:)` encodes this (past reset → `percentUsed: 0`,
  `resetsAt: nil`). It is applied in `StatuslinePipeline.displayWindow` (severity +
  notifications) and at the view layer (`UsageCardView`, widget `WindowRow`).

Parsing:

- `rate_limits.five_hour.used_percentage`
- `rate_limits.seven_day.used_percentage`
- `resets_at` as Unix epoch seconds
- Numeric JSON values must accept `Double`, `Int`, and `NSNumber`.
- Model/cost fields may be parsed, but shared snapshots must not persist
  high-sensitivity session identifiers from statusline.

Privacy:

- Do not persist statusline `session_id`, `session_name`, or `cwd` into the
  shared App Group snapshot.
- It is acceptable to persist lower-sensitivity model display name and aggregate
  cost/duration/line counts.

Parser version:

- `statusline-1.0`

### 4.2 Priority 2: Claude Code OAuth usage API

Pipeline: `OAuthPipeline`.

Endpoint:

- `GET https://api.anthropic.com/api/oauth/usage`

Headers:

- `Authorization: Bearer <access token>`
- `anthropic-beta: oauth-2025-04-20`
- `Accept: application/json`

Session:

- Use `URLSessionConfiguration.ephemeral`.
- `httpShouldSetCookies = false`.
- `httpCookieAcceptPolicy = .never`.
- Request timeout: 10 seconds.

Mode gate:

- `oauthMode == "auto"`: read Claude Code credentials.
- `oauthMode == "manual"`: read app-owned manual OAuth credentials.
- Empty `oauthMode`: OAuth layer falls through without calling API.
- `oauthSourceEnabled == false`: OAuth layer is not built at all.

Claude Code credentials:

- Service: `Claude Code-credentials`.
- Account: `NSUserName()` / current user.
- JSON block: `claudeAiOauth`.
- Required fields:
  - `accessToken`
  - `refreshToken`
  - `expiresAt` in integer milliseconds since epoch.
- Parse `expiresAt` from `Double`, `Int`, or `NSNumber`.

Manual credentials:

- Service: `com.jewei.claudemeter-oauth`.
- Account: `oauthManual`.
- Stored as the same JSON shape under `claudeAiOauth`.

Keychain implementation:

- On macOS / when Security.framework is available, read/write generic passwords
  with Security.framework APIs.
- Do not pass token JSON as command-line argv to `/usr/bin/security`.
- Non-Security fallback may use `/usr/bin/security`; it is not the macOS
  production path.

Token refresh:

- Refresh when expired or within 60 seconds of expiry.
- Endpoint: `POST https://console.anthropic.com/v1/oauth/token`
- JSON body:
  - `grant_type = "refresh_token"`
  - `refresh_token`
  - `client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"`
- If refresh succeeds, update Keychain best-effort.
- In-memory cached credentials survive within app session if Keychain write
  fails.

Concurrency:

- `OAuthPipeline` is `@unchecked Sendable`.
- Mutable `cachedCredentials` must be protected by a serial queue or equivalent.

API response:

- Decode the full response object, not `[String: QuotaEntry]`, because the API
  includes unrelated fields (`limits`, `spend`, `extra_usage`, nulls).
- `utilization` is already a 0...100 percentage.
- Do not multiply utilization by 100.

Parser version:

- `oauth-api-1.0`

### 4.3 Priority 3: claude.ai usage API

Pipeline: `ClaudeAIPipeline`.

Endpoint:

- `GET https://claude.ai/api/organizations/{orgId}/usage`

Header:

- `Cookie: sessionKey=<session key>`

Session:

- Use `URLSessionConfiguration.ephemeral`.
- `httpShouldSetCookies = false`.
- `httpCookieAcceptPolicy = .never`.
- Do not use `URLSession.shared`, because it can interfere with manual Cookie
  headers.

Credentials:

- Stored by `ClaudeAIKeychain` in macOS Keychain.
- Service: `com.jewei.claudemeter`.
- Accounts:
  - `claudeai.sessionKey`
  - `claudeai.orgId`
- Session key is a browser cookie and must never be logged.
- Org ID is a UUID and is pasted manually by user.

Behavior:

- If `claudeAISourceEnabled == false`, this layer is not built.
- If credentials are missing, this layer is skipped.
- Auth failures (401/403) are fatal for this source and produce a parse error;
  do not fall back to cached snapshot on auth failure.
- Transient failures fall back to `CachedSnapshotPipeline` and surface a
  `ParseWarning` with field `claude.ai API`.
- Message counts from `JournalReader` may be included as `rawValueText` when
  available.

Parser version:

- `claude-ai-api-1.0`

### 4.4 Terminal fallback: cached snapshot

Pipeline: `CachedSnapshotPipeline`.

Behavior:

- Reads latest snapshot from `SnapshotStore`.
- Marks `snapshot.state.isStale = true`.
- Returns a warning field `cache` with message `Serving cached snapshot`.
- Throws `CachedSnapshotError.noSnapshot` if no snapshot exists.

Important:

- This is a fallback inside an enabled source pipeline.
- If global active is false or all source toggles are false, the app should not
  poll the cached snapshot just to update UI.

---

## 5. Widget

Target: `ClaudeMeterWidgetExtension`.

Rules:

- Widget is sandboxed.
- It reads from `SnapshotStore.appGroup(suiteName:)` only.
- It must not fall back to Application Support.
- If App Group is unavailable or no snapshot exists, show "No data" gracefully.

Timeline:

- Load latest snapshot.
- Compute thresholds from `AppGroupConfig.currentThresholds()`.
- Compute staleness from `AppGroupConfig.isSnapshotStale(..., now: entry.date)`.
- Refresh at the earlier of:
  - next reset time
  - 15 minutes from now

Families:

- `.systemSmall`
- `.systemMedium`
- `.systemLarge`

Design:

- Activity-ring look matching the popover (outer = weekly, inner = 5-hour,
  depleting; energy left) with energy rows. Adaptive cream/dark
  `containerBackground`.
- Widget duplicates its design tokens locally (`Color(widgetHex:)`, `WFont`); do
  not import app-target token files into the widget target.
- Fredoka/Nunito are bundled into the widget target too (its own
  `ATSApplicationFontsPath = Fonts`).

---

## 6. Notifications

`NotificationEngine` is an actor.

Authorization:

- Request notification authorization once if status is `.notDetermined`.
- Treat `.authorized` and `.provisional` as allowed.

Claude Attention:

- A `Stop` hook posts a turn-finished notification only for the main agent. Hook
  payloads with `agent_id` came from a subagent; consume those markers without
  emitting them. Subagent permission `Notification` events and blocking
  `StopFailure` events remain actionable and still surface.
- The hook marker filename carries a base64url `cmr-` route suffix: terminal
  client, controlling TTY, and an optional client locator. Notification `userInfo`
  carries the decoded route; other notification types carry none.
- Clicking the default notification action focuses Ghostty by working directory,
  Terminal/iTerm2 by TTY, or WezTerm by pane id. Warp has no public exact-pane
  route, so it activates the running app. If an exact route is absent or stale,
  activate the already-running terminal only; never launch an app or create a
  window. Ghostty may choose the first match when several terminals share a cwd.

Enablement:

- `enableNotifications` defaults to true when key is absent.

Thresholds:

- Use `AppGroupConfig.currentThresholds(defaults:)`, not raw standard defaults,
  so notifications match display/widget thresholds.

Trigger rules:

- Process notifications only for non-stale snapshots.
- Trigger when session or weekly usage crosses the warning/critical threshold; and
  a **"recovered"** level when a window the user was previously over — by its *raw*
  reading, so a reset/refill still counts — drops back to normal.
- One notification per `(scope, level, reset-window)`.
- If `resetsAt` is nil, the dedup key falls back to the start of the next local
  day (`fallbackResetAnchor`) so escalation still notifies.
- Critical suppresses warning if critical already fired for same scope/window.
- Copy uses the energy voice: warning/critical name the energy left ("…is at 9%.
  Maybe touch grass? 🌱"); recovered is "You're refueled! …back to 100%. 🎉".

Delivery:

- Quota threshold notifications have no sound; Claude Attention uses the user's
  configured default notification sound.
- Mark fired only after `UNUserNotificationCenter.add` succeeds.

Sparkle:

- Background scheduled update availability may post a gentle notification.
- User-triggered update checks are left to Sparkle's standard UI.

---

## 7. Diagnostics and sanitization

Diagnostics UI:

- Shows data source mode based on `parserVersion` prefix:
  - `statusline` -> Statusline bridge
  - `oauth` -> OAuth usage API
  - `claude-ai` -> claude.ai API
  - otherwise cached snapshot
- Shows last poll time/error.
- Shows parser warnings.
- Copies sanitized diagnostics text to clipboard.

Always sanitize before display/copy/logging:

- Email addresses -> `[redacted]`
- Home directory paths (`/Users/<name>/...`) -> `/Users/[redacted]`
- UUIDs -> `[redacted]`
- Claude session keys matching `sk-ant-*` -> `[redacted]`
- OAuth/OIDC tokens matching `oidc-*` -> `[redacted]`
- `Authorization: Bearer ...` -> `Bearer [redacted]`
- `sessionKey=...` cookie values -> `sessionKey=[redacted]`
- Labeled token fields:
  - `accessToken`
  - `access_token`
  - `refreshToken`
  - `refresh_token`
- Labeled CLI fields:
  - `Session name:`
  - `Organization:`
  - `Cwd:`
  - `Email:`
  - `Session id:`

---

## 8. Settings and persistence reference

### 8.1 UserDefaults

| Area          | Key                        | Type   | Default         | Notes                                                   |
| ------------- | -------------------------- | ------ | --------------- | ------------------------------------------------------- |
| Onboarding    | `hasCompletedOnboarding`   | Bool   | false           | First-run sheet gate                                    |
| Data          | `isActive`                 | Bool   | false           | Global active/inactive gate                             |
| Data          | `statuslineSourceEnabled`  | Bool   | true            | Source toggle, priority 1                               |
| Data          | `oauthSourceEnabled`       | Bool   | true            | Source toggle, priority 2                               |
| Data          | `claudeAISourceEnabled`    | Bool   | true            | Source toggle, priority 3                               |
| Data          | `oauthMode`                | String | `""`            | `""`, `auto`, or `manual`                               |
| Data          | `accountPlans`             | Dict   | `{}`            | User-set plan badge per account key (OAuth single-slot) |
| Data          | `accountNames`             | Dict   | `{}`            | User-set display name per account key                   |
| Appearance    | `cardStyle`                | String | `rings`         | Popover card style: `rings` or `bars`                   |
| Appearance    | `progressionMode`          | String | `left`          | `left` (energy remaining) or `used`                     |
| Appearance    | `menuBarAccount`           | String | `""`            | Menu-bar pin: `""`/`nearest`, or an account key         |
| Appearance    | `menuBarWindow`            | String | `nearest`       | Menu-bar number window: `nearest`/`5h`/`7d`/`both`      |
| Notifications | `warningThresholdPercent`  | Double | 80              | Slider 50–90; synced to App Group; drives meter colors  |
| Notifications | `criticalThresholdPercent` | Double | 95              | Slider 60–100; synced to App Group; drives meter colors |
| UI staleness  | `staleAfterSeconds`        | Double | 180             | Supported by `AppGroupConfig`; no Settings control      |
| Notifications | `enableNotifications`      | Bool   | true            | Missing key means enabled                               |
| Advanced      | `launchAtLogin`            | Bool   | false           | Synced with `SMAppService`                              |
| Updates       | `SUEnableAutomaticChecks`  | Bool   | Sparkle default | Sparkle setting                                         |

### 8.2 Keychain

| Purpose               | Service                       | Account               | Value                                   |
| --------------------- | ----------------------------- | --------------------- | --------------------------------------- |
| Claude Code OAuth     | `Claude Code-credentials`     | `NSUserName()`        | Claude Code JSON with `claudeAiOauth`   |
| Manual OAuth          | `com.jewei.claudemeter-oauth` | `oauthManual`         | Same JSON shape with app-entered tokens |
| claude.ai session key | `com.jewei.claudemeter`       | `claudeai.sessionKey` | Browser `sessionKey` cookie             |
| claude.ai org ID      | `com.jewei.claudemeter`       | `claudeai.orgId`      | UUID string                             |

### 8.3 App Group

Suite:

- `group.com.jewei.claudemeter`

App Group stores:

- Latest snapshot JSON.
- Last error JSON.
- Display settings synced from standard defaults.

---

## 9. Build and project maintenance

Build commands:

```bash
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO
swift test --package-path ClaudeMeterCore
```

Signing:

- App Group entitlement requires a real provisioning profile to run.
- `CODE_SIGNING_ALLOWED=NO` is enough for compilation checks.

Project file:

- `ClaudeMeter.xcodeproj/project.pbxproj` is hand-maintained.
- No xcodegen.
- Every new source file needs:
  - `PBXFileReference`
  - `PBXBuildFile`
  - group child entry
  - Sources/Frameworks build phase entry as appropriate
- Use consistent 24-character hex UUIDs.

Swift/concurrency:

- Core package should remain Swift 6 strict-concurrency friendly.
- Formatter singletons like `DateFormatter`, `NumberFormatter`, and
  `ISO8601DateFormatter` are not Sendable. Either create per call or isolate
  behind serial access / `nonisolated(unsafe)` only with a clear invariant.
- Do not call `queue.sync` from work already running on the same serial queue.
- Fire-and-forget work launched from `@MainActor` via `Task.detached` must only
  capture Sendable state.

---

## 10. Current tests to preserve/extend

Core tests cover:

- Diagnostics sanitizer.
- Credential validation.
- Claude AI error auth classification.
- OAuth keychain parsing.
- OAuth usage response decoding and percent scale.
- Statusline bridge refresh interval, integer percentage parsing, and invalid
  settings JSON guard.
- Snapshot store.
- Notification policy.
- Legacy parser/pipeline behavior retained for fixtures.

Future changes should add tests when modifying:

- source toggle pipeline composition
- active/inactive polling gate
- statusline bridge install/uninstall
- OAuth refresh behavior
- diagnostic redaction
- widget App Group-only reads

---

## 11. Explicitly discarded legacy features

These existed in older plans or code paths but are not part of the current
product behavior.

### 11.1 Removed from production behavior

- `~/.claude/stats-cache.json` as a user-facing setup path.
- `StatsCachePipeline` in the production poll chain.
- `StatsCacheReader` as a production data source.
- CLI status parsing as a production data source.
- Running `claude status` as a subprocess.
- Raw Claude CLI output collection as a user-facing diagnostic feature.
- User-configurable CLI path.
- User-configurable CLI timeout.
- Polling interval sliders.
- Statusline stale-after slider.
- API fallback cooldown slider.
- Stats-cache path setting.
- Daily/weekly manual message limit settings.
- Journal projects path setting.
- Privacy mode setting.

### 11.2 Removed UI/screens

- History view.
- Mini monitor view.
- SQLite-backed usage history.
- Charts/timelines based on retained history.
- Stats-cache onboarding copy.
- Stats-cache missing error copy.
- Model row kept only for stats-cache fallback.

### 11.3 Removed persistence/storage

- SQLite `HistoryStore`.
- `history.sqlite`.
- History retention setting (`historyRetentionDays`).
- sqlite3 linker dependency.

### 11.4 Removed legacy CLI stack

The following were removed from the package (previously kept for tests/previews only):

- `StatsCachePipeline`, `StatsCacheReader`, `SnapshotPipeline`
- `ClaudeOutputParser`, `CommandRunner`, `CLIPathDetector`, `ANSIStripper`, `TokenParser`, `ResetTimeParser`

`JournalReader` remains in production: `ClaudeAIPipeline` uses it for cosmetic message-count labels on the claude.ai tier.

---

## 12. Non-goals for a clean rebuild

Do not rebuild:

- Historical storage or charts.
- SQLite.
- Stats-cache-first onboarding.
- CLI scraping.
- A Dock app UI.
- A widget that reads outside the App Group.
- User-editable polling cadence.
- Multiple statusline bridge variants.
- Logging of raw credentials, cookies, session IDs, home paths, or emails.

The clean rebuild should be a small menu bar app with a core pipeline, one
latest snapshot, explicit pause/source controls, sanitized diagnostics, optional
notifications, and an App Group widget.
