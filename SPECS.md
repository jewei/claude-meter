# Claude Meter — SPECS.md

**Status:** Draft v0.3
**Date:** 2026-06-23
**Target platform:** macOS menu bar app (SwiftUI `MenuBarExtra`)
**Primary input source:** `claude.ai/api/organizations/{orgId}/usage` (HTTP API via session key)
**Fallback source:** `~/.claude/stats-cache.json` + `~/.claude/projects/**/*.jsonl`

---

## 1. Summary

Claude Meter is a macOS menu bar app that monitors Claude usage-limit state in a glanceable, always-visible status bar item. It runs persistently in the background, polls the claude.ai usage API on a configurable interval, and displays current session and weekly usage in a popover.

The app answers these questions at a glance:

- How much of the current Claude session limit is used?
- When does the current session reset?
- How much of the weekly all-model limit is used?
- When does the weekly limit reset?
- Is the data fresh or stale?

**Primary surface:** SwiftUI `MenuBarExtra` with `.window` popover style.
**No Dock icon** in production (`LSUIElement = YES`).
**WidgetKit extension** is available as an additional surface.

---

## 2. Goals

### 2.1 Product goals

1. Provide a compact, always-visible indication of Claude usage limits.
2. Surface reset times in the user's local timezone.
3. Warn before limits become blocking.
4. Degrade cleanly when the API is unreachable or the session key expires, falling back to local cache data.
5. Stay out of the user's way: small footprint, low CPU, no visible Dock icon.

### 2.2 Engineering goals

1. Keep the pipeline isolated from the UI — pure Swift, no AppKit/SwiftUI imports in core library.
2. Make API polling safe: bounded timeout, no overlapping polls, testable.
3. Store the latest snapshot in a simple JSON file; share via App Group with the WidgetKit extension.
4. Keep historical data separate from the live snapshot.
5. All shared state flows through a single observable data store.

---

## 3. Non-goals

1. Do not use the `claude` CLI as a subprocess for live data (it outputs a TUI, not plain text).
2. Do not scrape network traffic or bypass Claude plan limits.
3. Do not expose account email, organization, or cwd in logs.
4. Do not promise sub-15-second updates.
5. Do not support automated limit evasion, account rotation, or usage spoofing.

---

## 4. Key platform assumptions

1. The app runs as the user's macOS account.
2. The user has a Claude Pro/Max account and can obtain a session key from their browser cookies.
3. The claude.ai API (`/api/organizations/{orgId}/usage`) returns `five_hour.utilization`, `seven_day.utilization`, and `resets_at`.
4. Session keys expire when the user logs out of claude.ai or approximately every 90 days.
5. When the API is unavailable, `~/.claude/stats-cache.json` provides recent usage data (may lag by one session).
6. `stats-cache.json` dates are in the user's local calendar timezone.

---

## 5. API response example

Primary data source — `GET https://claude.ai/api/organizations/{orgId}/usage`:

```json
{
  "five_hour": {
    "utilization": 0.25,
    "resets_at": "2026-06-22T06:50:00Z"
  },
  "seven_day": {
    "utilization": 0.3,
    "resets_at": "2026-06-27T07:00:00Z"
  }
}
```

`utilization` is a fraction (0.0–1.0+). Multiply by 100 for percentage display.

---

## 6. User stories

### 6.1 Implemented

1. As a Claude user, I can glance at my menu bar and see current session usage percentage.
2. As a Claude user, I can click the menu bar item to see session and weekly usage in a popover.
3. As a Claude user, I can see reset times in my local timezone.
4. As a Claude user, I can tell whether the displayed data is fresh or stale.
5. As a Claude user, I can press "Refresh" to poll immediately.
6. As a Claude user, I can enter my session key and org ID in Settings to enable API-based data.
7. As a Claude user, I can quit the app from the popover footer.
8. As a Claude user, I can receive local notifications at configurable thresholds.
9. As a Claude user, I can view usage in a macOS desktop widget (WidgetKit).

### 6.2 Post-MVP

1. As a Claude user, I can see historical usage over the last 7 / 30 days as a chart.
2. As a Claude user, I can export local history to CSV or JSON.
3. As a Claude user, I can track multiple Claude accounts.

---

## 7. Functional requirements

### 7.1 App architecture

Claude Meter is a single macOS app target with **no Dock icon**. It lives entirely in the menu bar. Its responsibilities:

1. Load credentials from Keychain on startup.
2. Poll the claude.ai API (or fallback stats-cache) on a configurable interval.
3. Persist the latest snapshot to the App Group container.
4. Update the `MenuBarExtra` icon and popover reactively.
5. Deliver local notifications at configured thresholds.
6. Provide a settings panel reachable from the popover.
7. Provide a diagnostics view for debugging.

### 7.2 Menu bar icon

The icon conveys the highest-severity usage state at a glance.

**Icon variants:**

| State            | Display                     |
| ---------------- | --------------------------- |
| Normal (< 80%)   | `25%` text label            |
| Warning (80–94%) | Label with yellow tint      |
| Critical (≥ 95%) | Label with red tint         |
| Stale            | Icon with clock badge       |
| Error            | Icon with exclamation badge |
| Loading          | Animated spinner            |

**Label format:** Session percentage only (e.g. `25%`). Full details in the popover.

### 7.3 Popover — main view

Triggered by clicking the menu bar icon. Uses `.menuBarExtraStyle(.window)`.

**Popover layout (top to bottom):**

```
┌─────────────────────────────────────┐
│ Claude Meter           [⚙] [↻] [✕]  │  ← Header bar
├─────────────────────────────────────┤
│ CURRENT SESSION                     │
│ ████████████░░░░░░░░░░░ 25%         │
│ Resets in 42m                       │
├─────────────────────────────────────┤
│ THIS WEEK                           │
│ ███████████████░░░░░░░░ 30%         │
│ Resets Jun 27, 3:00 PM              │
├─────────────────────────────────────┤
│ Updated 14s ago    [Refresh] [⏻]    │  ← Footer
└─────────────────────────────────────┘
```

Footer actions:

1. Last updated age (auto-refreshes the display every second).
2. Refresh Now button.
3. Quit app button (power icon, calls `NSApplication.shared.terminate(nil)`).
4. Open Settings (gear icon in header).
5. Close popover (×).

### 7.4 Settings panel

Accessible via gear icon. Window floats above other windows (`NSWindow.level = .floating`). Width 480px.

**Data tab:**

- **Claude.ai Connection** section:
  - Session key field (plain/secure toggle with eye button, width 260px, placeholder `sk-ant-sid02-…`)
  - Org ID field (width 260px, placeholder `UUID`)
  - Connect / Test connection / Disconnect buttons
  - Test result feedback (shows "Session X% · Week Y%" or error)
- **Polling** section:
  - Poll interval when popover is open (default 15s)
  - Poll interval in background (default 60s)
  - Mark stale after (default 180s)

**Display tab:**

- **Severity Thresholds** section:
  - Warning threshold % (default 80%)
  - Critical threshold % (default 95%)

**Notifications tab:**

- Enable notifications toggle
- Per-trigger toggles (session warning, session critical, week warning, week critical)

**Advanced tab:**

- Launch at login toggle
- History retention days (default 180)
- Diagnostics button

### 7.5 Diagnostics view

A secondary view showing:

1. Data source mode (claude.ai API vs stats cache + journal).
2. Last poll time.
3. Last error message.
4. Parser warnings list.
5. Parser version and snapshot schema version.
6. Snapshot creation time.
7. History record count and store path.
8. "Copy sanitized diagnostics" button — redacts email, home paths, labeled fields.

---

## 8. Data collection

### 8.1 Primary: claude.ai API client

```swift
public struct ClaudeAIUsageClient: Sendable {
    public let sessionKey: String
    public let orgId: String
    public func fetchUsage() async throws -> UsageData
}
```

Endpoint: `GET https://claude.ai/api/organizations/{orgId}/usage`

Auth: `Cookie: sessionKey=<value>` header (manual, not system cookie storage).

Session config: `URLSessionConfiguration.ephemeral` with `httpShouldSetCookies = false` and `httpCookieAcceptPolicy = .never` to prevent system cookie interference.

Error types: `unauthorized` (401), `httpError(Int)`, `missingFields`, `invalidURL`, `invalidResponse`.

### 8.2 Fallback: stats-cache + journal

Used when no Keychain credentials exist, or when the API call throws any error.

- `StatsCacheReader` reads `~/.claude/stats-cache.json` for session/week usage percentages.
- `JournalReader` scans `~/.claude/projects/**/*.jsonl` for real-time message counts (supplements stale cache).
- API failure is surfaced as a `ParseWarning` in the result; UI still shows fallback data.

### 8.3 Pipeline protocol

```swift
public protocol ClaudeMeterPipeline: Sendable {
    func poll(now: Date) async throws -> ParseResult
}
```

`ClaudeAIPipeline` and `StatsCachePipeline` both conform. `AppState.pipeline` is typed as `any ClaudeMeterPipeline`.

### 8.4 Polling rules

1. Polling is performed by a background `Task` while the app is running.
2. Skip if a poll is already in flight.
3. Apply exponential backoff (cap at 5 minutes) on repeated failures.
4. Advance `lastPolledAt` only on successful snapshot updates.
5. Reload WidgetKit timelines after each successful poll.

**Default poll intervals:**

| Condition       | Interval |
| --------------- | -------- |
| Popover visible | 15 s     |
| Background      | 60 s     |

---

## 9. Credential storage

Session key and org ID are stored in the macOS Keychain:

- **Service:** `com.jewei.claudemeter`
- **Session key account:** `claudeai.sessionKey`
- **Org ID account:** `claudeai.orgId`

Wrapper: `ClaudeAIKeychain` (enum with `save`, `load`, `delete` static methods).

The main app target is not sandboxed; Security framework works without special entitlements.

Never log or display the raw session key. The diagnostics sanitizer already redacts home paths and email — session keys are not stored anywhere that gets logged.

---

## 10. Data model

### 10.1 Snapshot JSON schema

Written atomically to the App Group container:

```text
~/Library/Group Containers/group.com.jewei.claudemeter/current.json
```

```json
{
  "schemaVersion": 1,
  "parserVersion": "0.1.0",
  "createdAt": "2026-06-22T06:45:00Z",
  "lastSuccessfulPollAt": "2026-06-22T06:45:00Z",
  "source": {
    "cliPath": "",
    "command": "claude.ai API"
  },
  "limits": {
    "currentSession": {
      "percentUsed": 25.0,
      "resetsAt": "2026-06-22T06:50:00Z",
      "rawValueText": "42 msgs"
    },
    "currentWeekAllModels": {
      "percentUsed": 30.0,
      "resetsAt": "2026-06-27T07:00:00Z"
    }
  },
  "state": {
    "status": "ok",
    "severity": "normal"
  }
}
```

### 10.2 Core Swift types

```swift
struct ClaudeUsageSnapshot: Codable, Equatable {
    var schemaVersion: Int
    var parserVersion: String
    var createdAt: Date
    var lastSuccessfulPollAt: Date?
    var source: SourceInfo
    var session: SessionInfo?        // activeModel only; name/cwd not populated
    var limits: LimitInfo
    var state: SnapshotState
}

struct LimitInfo: Codable, Equatable {
    var currentSession: LimitWindow
    var currentWeekAllModels: LimitWindow
}

struct LimitWindow: Codable, Equatable {
    var percentUsed: Double?
    var resetsAt: Date?
    var rawResetText: String?
    var rawValueText: String?        // "N msgs" for fallback display
}
```

### 10.3 Enums

```swift
enum SnapshotStatus: String, Codable {
    case ok
    case stale
    case unauthenticated
    case parseError
    case unknownError
}

enum UsageSeverity: String, Codable {
    case normal      // 0..<80
    case warning     // 80..<95
    case critical    // 95...100
    case overLimit   // >100
    case unknown
}
```

---

## 11. Storage

### 11.1 Live snapshot

Written atomically (write temp → rename):

```text
group.com.jewei.claudemeter/current.json       ← primary (App Group)
~/Library/Application Support/ClaudeMeter/current.json  ← legacy fallback
```

### 11.2 Preferences

Stored in `UserDefaults` standard suite. Display settings (thresholds, staleAfterSeconds) are synced to the App Group suite so the widget can read them without the app being running.

### 11.3 Historical storage

SQLite in the app container:

```text
group.com.jewei.claudemeter/history.sqlite
```

Records are pruned on append to `historyRetentionDays` (default 180). Keeps the most recent N records (DESC limit, then reverse).

---

## 12. UI states

### 12.1 No credentials

```
Claude Meter
Open Settings → Data to connect to claude.ai.
[Open Settings]
```

### 12.2 Loading state

Initial poll in flight.

```
Checking…
```

### 12.3 OK state (< 80%)

```
CURRENT SESSION      25%
████████░░░░░░░░░░░░
Resets in 2h 10m

THIS WEEK            30%
████████████░░░░░░░░
Resets Jun 27, 3:00 PM
```

### 12.4 Warning state (80–94%)

```
CURRENT SESSION      84%
████████████████░░░░
Resets in 42m
```

### 12.5 Critical state (≥ 95%)

```
CURRENT SESSION      96%
████████████████████
Resets in 9m
```

### 12.6 Stale state

Data exists but older than `staleAfterSeconds`.

### 12.7 Error / fallback state

When API fails, data from stats-cache is shown with a warning in diagnostics. No error is shown in the popover if usable data is available.

---

## 13. Visual design

1. Dark glassmorphism aesthetic with `.ultraThinMaterial` background.
2. Progress bars: capsule shape with glow on fill.
3. Severity colors: normal → green `#4be257`; warning → yellow `#fdbb2c`; critical → red `#ff5f56`.
4. Monospaced digits for all percentages and countdowns.
5. Percent always visible; do not rely on color alone for state.
6. Values > 100% display as `100%+`.
7. Reset time is more prominent than secondary stats.

---

## 14. Notifications

Local `UserNotifications` from the app. No sound by default.

**Triggers:**

1. Session usage crosses warning threshold (80%).
2. Session usage crosses critical threshold (95%).
3. Weekly usage crosses warning threshold (80%).
4. Weekly usage crosses critical threshold (95%).
5. Session reset occurs (optional, disabled by default).

**Deduplication:**

1. Notify once per threshold crossing per reset window.
2. Do not repeat warning after critical has fired.
3. Reset notification state after the corresponding reset time passes.
4. Do not notify if data is stale.
5. If `resetsAt` is nil, use start of today UTC as the dedup anchor.

---

## 15. Settings schema

**Stored in UserDefaults standard suite (unless noted):**

| Setting                         | Type   | Default |
| ------------------------------- | ------ | ------- |
| `pollIntervalActiveSeconds`     | Double | `15`    |
| `pollIntervalBackgroundSeconds` | Double | `60`    |
| `staleAfterSeconds`             | Double | `180`   |
| `warningThresholdPercent`       | Double | `80`    |
| `criticalThresholdPercent`      | Double | `95`    |
| `launchAtLogin`                 | Bool   | `false` |
| `enableNotifications`           | Bool   | `true`  |
| `historyRetentionDays`          | Int    | `180`   |

**Stored in macOS Keychain (service `com.jewei.claudemeter`):**

| Key                   | Purpose                  |
| --------------------- | ------------------------ |
| `claudeai.sessionKey` | claude.ai browser cookie |
| `claudeai.orgId`      | Organization UUID        |

Removed settings (no longer in codebase): `claudeCliPath`, `statusCommand`, `statsCommand`, `cliTimeoutSeconds`, `privacyMode`, `enableDiagnosticsRawOutput`, `dailyMessageLimit`, `weeklyMessageLimit`, `statsCachePath`, `journalProjectsPath`.

---

## 16. Security and privacy

1. **Session key stored in macOS Keychain** — never written to disk in plaintext, never logged.
2. No analytics.
3. Diagnostics sanitizer redacts: email addresses → `[redacted]`, home directory paths → `/Users/[redacted]/…`, labeled fields (Session name, Organization, Email, etc.) → `[redacted]`.
4. Preferences stored locally; no cloud sync.
5. The session key is a browser session cookie. It has the same access as the logged-in browser — treat it as a credential.
6. The app makes outbound HTTPS calls to `claude.ai` only; no other network endpoints.

---

## 17. Accessibility

1. All progress bars have text equivalents (`.accessibilityLabel`).
2. VoiceOver label: `"Session usage 25 percent, resets in 2 hours 10 minutes. Weekly usage 30 percent, resets June 27 at 3 PM."`.
3. Warning/critical state conveyed through color AND icon/text.
4. All popover controls keyboard navigable.

---

## 18. Error handling

| Condition           | Behavior                                             |
| ------------------- | ---------------------------------------------------- |
| No credentials      | Show setup prompt in popover                         |
| API 401             | Show "Session key invalid or expired" warning        |
| API error / timeout | Fall back to stats-cache; show warning in diag       |
| Stats-cache missing | Show "No data" state                                 |
| Stale snapshot      | Show clock badge; popover shows "Last updated X ago" |

---

## 19. Testing

### 19.1 Core library tests

- `StatsCacheReader` parses known `stats-cache.json` fixture correctly.
- `JournalReader` counts today's messages from JSONL fixture.
- `ClaudeAIPipeline` falls back and adds warning when `ClaudeAIUsageClient` throws.
- `HistoryStore` prunes to retention cutoff on append.
- `SnapshotStore` performs atomic write and reads back correctly.
- `NotificationEngine` deduplicates within the same reset window.
- `DiagnosticsSanitizer` redacts email, home path, labeled fields.

### 19.2 Legacy parser tests (kept for regression coverage)

`ClaudeOutputParser` and `SnapshotPipeline` tests remain but are not exercised in production; the CLI output path is removed.

---

## 20. Acceptance criteria

MVP is complete when:

1. The app polls `claude.ai/api/organizations/{orgId}/usage` and displays session/week usage percentages.
2. Session key and org ID are stored/loaded from Keychain.
3. The API failure path falls back to stats-cache and shows usable data.
4. The popover renders session and weekly cards with progress bars and reset times.
5. The menu bar label shows session percentage only; clicking reveals both cards.
6. Severity thresholds affect icon color and notification triggers.
7. Settings panel: Data tab allows connecting/disconnecting the session; Display tab allows threshold adjustment.
8. Diagnostics view shows current mode (API vs fallback) and last error.
9. Widget shows session and week data from the App Group snapshot.

---

## 21. Glossary

| Term            | Meaning                                                                        |
| --------------- | ------------------------------------------------------------------------------ |
| Popover         | The SwiftUI `MenuBarExtra` `.window` view shown when clicking the icon         |
| Snapshot        | Latest parsed usage state persisted to `current.json`                          |
| Current session | Claude's rolling 5-hour usage window                                           |
| Current week    | Claude's weekly all-model usage window                                         |
| Stale           | Snapshot older than `staleAfterSeconds`                                        |
| Severity        | `normal` / `warning` / `critical` / `overLimit` based on percentage thresholds |
| Session key     | Browser cookie (`sk-ant-sid02-…`) used to authenticate claude.ai API calls     |
| Org ID          | UUID identifying the user's Claude organization                                |

---

## 22. Implementation phases (historical reference)

- **Phase 1** — Parser and fixture harness ✅
- **Phase 2** — Data pipeline (CLI subprocess) ✅ (now superseded by API pipeline)
- **Phase 3** — MenuBarExtra app shell ✅
- **Phase 4** — Notifications ✅
- **Phase 5** — Settings and onboarding ✅
- **Phase 6** — WidgetKit extension ✅
- **Phase 7** — History and polish ✅
- **Phase 8** — claude.ai API as primary source (replaced CLI), Keychain credential storage, Privacy Mode removed ✅
