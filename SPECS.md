# Claude Meter — SPECS.md

**Status:** Draft v0.2
**Date:** 2026-06-22
**Target platform:** macOS menu bar app (SwiftUI `MenuBarExtra`)
**Primary input source:** `claude status` CLI output

---

## 1. Summary

Claude Meter is a macOS menu bar app that monitors Claude usage-limit state in a glanceable, always-visible status bar item. It runs persistently in the background, polls the local `claude` CLI on a configurable interval, parses the output, and displays current session and weekly usage in a popover.

The app answers these questions at a glance:

- How much of the current Claude session limit is used?
- When does the current session reset?
- How much of the weekly all-model limit is used?
- When does the weekly limit reset?
- Which model/session is active?
- Is the Claude CLI reachable, authenticated, stale, or failing?

**Primary surface:** SwiftUI `MenuBarExtra` with `.window` popover style.
**No Dock icon** in production (`LSUIElement = YES`).
**WidgetKit extension** is deferred to a post-MVP phase (see §23).

---

## 2. Goals

### 2.1 Product goals

1. Provide a compact, always-visible indication of Claude usage limits.
2. Surface reset times in the user's local timezone.
3. Warn before limits become blocking.
4. Work without any external server or network calls.
5. Preserve privacy — all data stays local.
6. Degrade cleanly when the CLI output changes, is unavailable, or is unauthenticated.
7. Stay out of the user's way: small footprint, low CPU, no visible Dock icon.

### 2.2 Engineering goals

1. Keep the parser isolated from the UI — pure Swift, no AppKit/SwiftUI imports.
2. Make CLI polling safe: bounded timeout, no overlapping polls, testable.
3. Store the latest snapshot in a simple JSON file; share via App Group only when WidgetKit is added.
4. Keep historical data separate from the live snapshot.
5. Provide fixtures for every known CLI output variant.
6. All shared state flows through a single observable data store.

---

## 3. Non-goals (MVP)

1. Do not build a WidgetKit widget (Phase 6).
2. Do not build a floating desktop overlay window (Phase 7).
3. Do not require a cloud backend.
4. Do not reverse-engineer undocumented Claude service internals.
5. Do not scrape network traffic or bypass Claude plan limits.
6. Do not expose account email, organization, or cwd in logs by default.
7. Do not promise sub-15-second updates.
8. Do not support automated limit evasion, account rotation, or usage spoofing.

---

## 4. Key platform assumptions

1. The app runs as the user's macOS account and can execute the local `claude` CLI.
2. The CLI output is text-only and may change across Claude CLI versions.
3. If Claude CLI exposes stable JSON output in a future version, prefer JSON over text parsing.
4. Reset times in CLI output may use natural-language dates and IANA timezone names:
   - `2:50pm (Asia/Kuala_Lumpur)`
   - `Jun 27 at 3pm (Asia/Kuala_Lumpur)`
5. Percentages shown by the CLI are authoritative when present.
6. Token/cost/model statistics are informational; do not use them as the source of truth for limit percentages.
7. The `claude` binary may live in `/opt/homebrew/bin`, `/usr/local/bin`, or a user-specified path.

---

## 5. Example CLI input

The initial parser must support output structurally similar to:

```text
Current session
████████████▌                                      25% used
Resets 2:50pm (Asia/Kuala_Lumpur)

Current week (all models)
███████████████                                    30% used
Resets Jun 27 at 3pm (Asia/Kuala_Lumpur)
```

And relevant surrounding fields:

```text
Version:          2.1.185
Session name:     Implement fraud detection score weighting
Session ID:       d49ac283-b694-4873-853d-eeaf873aaad4
cwd:              /Users/jewei/OneVerse/Code/games
Login method:     Claude Pro account
Organization:     jewei.mak@gmail.com's Organization
Email:            jewei.mak@gmail.com

Model:            claude-opus-4-8
MCP servers:      8 connected, 3 need auth, 1 failed · /mcp
Setting sources:  User settings, Project local settings
```

---

## 6. User stories

### 6.1 MVP

1. As a Claude user, I can glance at my menu bar and see current session usage percentage.
2. As a Claude user, I can click the menu bar item to see session and weekly usage in a popover.
3. As a Claude user, I can see reset times in my local timezone.
4. As a Claude user, I can tell whether the displayed data is fresh or stale.
5. As a Claude user, I can press "Refresh" to poll immediately.
6. As a Claude user, I can configure which Claude binary path is used.
7. As a Claude user, I can choose whether to show or hide sensitive fields (email, cwd, session name).

### 6.2 Post-MVP

1. As a Claude user, I can see historical usage over the last 7 / 30 days.
2. As a Claude user, I can receive local notifications at configurable thresholds.
3. As a Claude user, I can view usage in a macOS desktop widget (WidgetKit).
4. As a Claude user, I can export local history to CSV or JSON.
5. As a Claude user, I can track multiple Claude accounts if the CLI supports profile switching.

---

## 7. Functional requirements

### 7.1 App architecture

Claude Meter is a single macOS app target with **no Dock icon**. It lives entirely in the menu bar. Its responsibilities:

1. Detect and auto-configure the `claude` CLI path on first launch.
2. Poll the CLI on a configurable interval while running.
3. Parse CLI output into a typed snapshot.
4. Persist the latest snapshot to disk.
5. Update the `MenuBarExtra` icon and popover reactively.
6. Deliver local notifications at configured thresholds.
7. Provide a settings panel reachable from the popover.
8. Provide a diagnostics view for parser/CLI debugging.

### 7.2 Menu bar icon

The icon in the status bar conveys the highest-severity usage state at a glance.

**Icon variants:**

| State            | Display                              |
| ---------------- | ------------------------------------ |
| Normal (< 80%)   | `claude 25%` or SF Symbol brain icon |
| Warning (80–94%) | Icon with yellow tint                |
| Critical (≥ 95%) | Icon with red tint                   |
| Stale            | Icon with clock badge                |
| Error            | Icon with exclamation badge          |
| Loading          | Animated spinner                     |

**Example text labels:**

```text
claude 25%/30%
claude 92% ·18m
```

The label string is short enough to fit the status bar without truncation. Prefer the percentage over a long label.

### 7.3 Popover — main view

Triggered by clicking the menu bar icon. Uses `.menuBarExtraStyle(.window)` to render a SwiftUI view.

**Popover layout (top to bottom):**

```
┌─────────────────────────────────────┐
│ Claude Meter           [⚙] [↻] [✕]  │  ← Header bar
├─────────────────────────────────────┤
│ SESSION                             │
│ ████████████░░░░░░░░░░░ 25%         │
│ Resets 2:50 PM                      │
├─────────────────────────────────────┤
│ WEEK (ALL MODELS)                   │
│ ███████████████░░░░░░░░ 30%         │
│ Resets Jun 27, 3:00 PM              │
├─────────────────────────────────────┤
│ Model   claude-opus-4-8             │
│ Session Implement fraud detection…  │  ← hidden in minimal/anon modes
├─────────────────────────────────────┤
│ Updated 14s ago          [Refresh]  │  ← Footer
└─────────────────────────────────────┘
```

Required footer actions:

1. Last updated age (auto-refreshes the display every second).
2. Refresh Now button.
3. Open Settings (gear icon in header).
4. Quit (right-click the menu bar icon, or a dedicated menu item).

### 7.4 Settings panel

Accessible via gear icon. A standard SwiftUI sheet or separate `Settings` scene.

Sections:

1. **CLI** — binary path, status/stats subcommand, poll intervals, timeout.
2. **Display** — privacy mode, display timezone, show/hide fields.
3. **Thresholds** — warning %, critical %.
4. **Notifications** — enable/disable, per-trigger toggles.
5. **Advanced** — login shell, raw diagnostics enable, history retention.
6. **Diagnostics** — button to open diagnostics view.

### 7.5 Diagnostics view

A secondary view showing:

1. CLI path and detected version.
2. Last command run, duration, exit code.
3. Last successful / last failed poll time.
4. Last error message.
5. Parser warnings list.
6. Parser version and snapshot schema version.
7. Sanitized raw output preview (redacted by default).
8. "Copy sanitized diagnostics" button.
9. "Reveal raw output" button (gated by confirmation).

---

## 8. Data collection

### 8.1 CLI command abstraction

```swift
protocol ClaudeCommandRunner {
    func fetchStatus() async throws -> String
    func fetchStatsOverview() async throws -> String?
}
```

Default commands (user-configurable):

```text
claude status
claude stats
```

### 8.2 PATH for subprocess execution

Run the CLI with a predictable, minimal environment:

```
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

Advanced option: run via the user's login shell (disabled by default).

Process rules:

- Hard timeout: 5 seconds (configurable).
- Capture stdout and stderr separately.
- Cancel the process if the timeout fires before completion.
- Do not source shell initialization files unless login-shell mode is enabled.

### 8.3 Polling rules

1. Polling is performed by the app's background task, triggered by a `Timer` while the app is running.
2. Skip if a poll is already in flight.
3. Apply exponential backoff (cap at 5 minutes) on repeated CLI failures.
4. Trigger snapshot update when any material field changes:
   - session usage percentage
   - weekly usage percentage
   - reset time
   - error state
   - stale/fresh transition
5. Always update `lastUpdatedAt` when a poll succeeds.
6. Store the raw CLI output only if diagnostics logging is enabled.

**Default poll intervals:**

| Condition                  | Interval |
| -------------------------- | -------- |
| Popover visible            | 15 s     |
| App active, popover hidden | 60 s     |
| App in background          | 60 s     |

---

## 9. Parsing requirements

### 9.1 Parser architecture

Layer the parser:

1. Normalize terminal text (line endings, trailing whitespace).
2. Strip ANSI escape codes.
3. Split into named sections.
4. Parse key-value fields (e.g. `Model: claude-opus-4-8`).
5. Parse usage-limit blocks (progress bar + percent + reset line).
6. Parse model usage table.
7. Emit a strongly typed `ParseResult` with snapshot, warnings, errors, rawHash.

### 9.2 Normalization

1. Preserve Unicode progress characters (`█`, `░`, `▌`).
2. Normalize line endings to `\n`.
3. Remove ANSI color/style escape sequences (`\u{1B}[...m`).
4. Trim trailing whitespace from each line.
5. Collapse repeated blank lines only for section detection.
6. Do not lowercase — model names and session names are case-sensitive.

### 9.3 Required parsed fields

**From `status` command:**

| Field                       | Required | Example                                     |
| --------------------------- | -------: | ------------------------------------------- |
| `cliVersion`                |       No | `2.1.185`                                   |
| `sessionName`               |       No | `Implement fraud detection score weighting` |
| `sessionId`                 |       No | `d49ac283-b694-4873-853d-eeaf873aaad4`      |
| `cwd`                       |       No | `/Users/jewei/OneVerse/Code/games`          |
| `loginMethod`               |       No | `Claude Pro account`                        |
| `organization`              |       No | `jewei.mak@gmail.com's Organization`        |
| `email`                     |       No | `jewei.mak@gmail.com`                       |
| `activeModel`               |       No | `claude-opus-4-8`                           |
| `mcpServersRaw`             |       No | `8 connected, 3 need auth, 1 failed · /mcp` |
| `settingSources`            |       No | `User settings, Project local settings`     |
| `currentSessionPercentUsed` |  **Yes** | `25`                                        |
| `currentSessionResetsAt`    |  **Yes** | resolved UTC timestamp                      |
| `currentWeekPercentUsed`    |  **Yes** | `30`                                        |
| `currentWeekResetsAt`       |  **Yes** | resolved UTC timestamp                      |

**From `stats` command (optional):**

| Field                     | Required | Example |
| ------------------------- | -------: | ------- |
| `totalCostUsd`            |       No | `21.20` |
| `totalApiDurationSeconds` |       No | `4047`  |
| `codeLinesAdded`          |       No | `994`   |
| `codeLinesRemoved`        |       No | `471`   |

**Per model (from stats table):**

| Field              | Required | Example           |
| ------------------ | -------: | ----------------- |
| `modelName`        |      Yes | `claude-opus-4-8` |
| `inputTokens`      |       No | `23600`           |
| `outputTokens`     |       No | `40200`           |
| `cacheReadTokens`  |       No | `5800000`         |
| `cacheWriteTokens` |       No | `288200`          |
| `costUsd`          |       No | `6.89`            |

### 9.4 Progress block parsing

Detect usage blocks by their header line:

```text
Current session
...bar...
25% used
Resets 2:50pm (Asia/Kuala_Lumpur)

Current week (all models)
...bar...
30% used
Resets Jun 27 at 3pm (Asia/Kuala_Lumpur)
```

Rules:

1. The progress bar line is optional; ignore it visually.
2. The `% used` line is authoritative.
3. Percentages may be integer or decimal.
4. Clamp display to `0...100`; preserve raw value for diagnostics if CLI emits overage.
5. Reset line may appear before or after percent — scan the whole block.
6. If multiple matches, prefer the first match after the relevant section header.

### 9.5 Reset time parsing

Support formats:

```text
Resets 2:50pm (Asia/Kuala_Lumpur)
Resets Jun 27 at 3pm (Asia/Kuala_Lumpur)
Resets June 27 at 3:00 PM (Asia/Kuala_Lumpur)
```

Rules:

1. Extract timezone from the parenthesized IANA identifier when present.
2. If no timezone, use the user's configured display timezone.
3. If date is omitted, assume the next occurrence of that wall-clock time today.
4. If the inferred reset is more than 24 hours in the past, roll forward one day.
5. If year is omitted, infer the nearest future date.
6. Store timestamps in UTC; render in the user's selected display timezone.
7. Preserve the raw reset text for diagnostics.

### 9.6 Token shorthand parsing

| Suffix |    Multiplier |
| ------ | ------------: |
| none   |             1 |
| `k`    |         1,000 |
| `m`    |     1,000,000 |
| `b`    | 1,000,000,000 |

Examples: `8.4k` → `8400`, `22.6m` → `22600000`.

### 9.7 Parser output

```swift
struct ParseResult {
    var snapshot: ClaudeUsageSnapshot?
    var warnings: [ParseWarning]
    var errors: [ParseError]
    var rawHash: String
    var parserVersion: String
}
```

**Fatal errors** (no usable snapshot):

- No CLI output.
- CLI process timed out.
- No usage-limit blocks found.
- Output indicates unauthenticated CLI.
- Unsupported output format.

**Non-fatal warnings** (snapshot still usable):

- Could not parse model usage table.
- Could not parse cost.
- Could not parse MCP server counts.
- Reset timezone missing.
- Unknown model name format.

---

## 10. Data model

### 10.1 Snapshot JSON schema

The latest snapshot is written atomically to:

```text
~/Library/Application Support/ClaudeMeter/current.json
```

(When a WidgetKit extension is added in Phase 6, this moves to the App Group container.)

```json
{
  "schemaVersion": 1,
  "parserVersion": "0.1.0",
  "createdAt": "2026-06-22T06:45:00Z",
  "lastSuccessfulPollAt": "2026-06-22T06:45:00Z",
  "source": {
    "cliPath": "/opt/homebrew/bin/claude",
    "cliVersion": "2.1.185",
    "command": "claude status"
  },
  "account": {
    "loginMethod": "Claude Pro account",
    "organization": "jewei.mak@gmail.com's Organization",
    "email": "jewei.mak@gmail.com"
  },
  "session": {
    "id": "d49ac283-b694-4873-853d-eeaf873aaad4",
    "name": "Implement fraud detection score weighting",
    "cwd": "/Users/jewei/OneVerse/Code/games",
    "activeModel": "claude-opus-4-8",
    "totalCostUsd": 21.20,
    "totalApiDurationSeconds": 4047,
    "codeLinesAdded": 994,
    "codeLinesRemoved": 471
  },
  "limits": {
    "currentSession": {
      "percentUsed": 25.0,
      "resetsAt": "2026-06-22T06:50:00Z",
      "rawResetText": "2:50pm (Asia/Kuala_Lumpur)"
    },
    "currentWeekAllModels": {
      "percentUsed": 30.0,
      "resetsAt": "2026-06-27T07:00:00Z",
      "rawResetText": "Jun 27 at 3pm (Asia/Kuala_Lumpur)"
    }
  },
  "models": [
    {
      "name": "claude-opus-4-8",
      "inputTokens": 23600,
      "outputTokens": 40200,
      "cacheReadTokens": 5800000,
      "cacheWriteTokens": 288200,
      "costUsd": 6.89
    }
  ],
  "mcp": {
    "connected": 8,
    "needsAuth": 3,
    "failed": 1,
    "raw": "8 connected, 3 need auth, 1 failed · /mcp"
  },
  "state": {
    "status": "ok",
    "isStale": false,
    "severity": "normal",
    "message": null
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
    var source: ClaudeSourceInfo
    var account: ClaudeAccountInfo?
    var session: ClaudeSessionInfo?
    var limits: ClaudeLimitInfo
    var models: [ClaudeModelUsage]
    var mcp: ClaudeMCPStatus?
    var state: SnapshotState
}

struct ClaudeLimitInfo: Codable, Equatable {
    var currentSession: LimitWindow
    var currentWeekAllModels: LimitWindow
}

struct LimitWindow: Codable, Equatable {
    var percentUsed: Double?
    var resetsAt: Date?
    var rawResetText: String?
}
```

### 10.3 Enums

```swift
enum SnapshotStatus: String, Codable {
    case ok
    case stale
    case cliNotFound
    case cliTimedOut
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

Written atomically (write temp → fsync → rename):

```text
~/Library/Application Support/ClaudeMeter/current.json
~/Library/Application Support/ClaudeMeter/last-error.json
~/Library/Application Support/ClaudeMeter/current.raw.txt   ← diagnostics only
```

Writing rules:

1. Write to a `.tmp` file in the same directory.
2. fsync the temp file.
3. Atomically rename to `current.json`.
4. Always include `schemaVersion`.
5. Never let partial writes be readable.

### 11.2 Preferences

Stored in `UserDefaults` (standard suite for MVP; `AppGroup` suite when widget is added).

### 11.3 Historical storage (post-MVP)

SQLite in the app container:

```text
~/Library/Application Support/ClaudeMeter/history.sqlite
```

```sql
CREATE TABLE usage_snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL,
  raw_hash TEXT NOT NULL,
  session_id TEXT,
  active_model TEXT,
  session_percent REAL,
  session_resets_at TEXT,
  week_percent REAL,
  week_resets_at TEXT,
  total_cost_usd REAL,
  status TEXT NOT NULL
);
CREATE INDEX idx_created_at ON usage_snapshots(created_at);
```

---

## 12. UI states

### 12.1 Setup state

No CLI found or no snapshot yet.

```
Claude Meter
Open Settings to configure the CLI path.
[Open Settings]
```

### 12.2 Loading state

Initial poll in flight.

```
Checking Claude…
```

### 12.3 OK state (< 80%)

```
SESSION          25%
████████░░░░░░░░░░░░
Resets 2:50 PM

WEEK (ALL MODELS)  30%
████████████░░░░░░░░
Resets Jun 27, 3:00 PM
```

### 12.4 Warning state (80–94%)

Highlight the warning field. Show reset countdown.

```
SESSION          84% ⚠
████████████████░░░░
Resets in 42m
```

### 12.5 Critical state (≥ 95%)

```
SESSION          96% ⛔
████████████████████
Limit nearly reached
Resets in 9m
```

### 12.6 Stale state

Data exists but older than `staleAfterSeconds`.

```
Claude Meter
Last updated 8m ago
[Refresh Now]
```

### 12.7 Error states

```
Claude CLI not found
[Open Settings]

Claude not logged in
Run: claude login

Could not parse output
[Open Diagnostics]
```

---

## 13. Visual design

See DESIGN.md for the full design system. Summary:

1. Dark glassmorphism aesthetic with `.ultraThinMaterial` background.
2. Progress bars: 4px tall, capsule shape, glow on fill.
3. Severity colors: normal → primary blue; warning → yellow; critical → red.
4. Monospaced digits for all percentages and countdowns.
5. Percent always visible; do not rely on color alone for state.
6. Values > 100% display as `100%+`.
7. Reset time is more prominent than secondary stats.

### 13.1 Privacy modes

| Mode                  | Behavior                                        |
| --------------------- | ----------------------------------------------- |
| Full                  | Show session name, cwd, email, org              |
| Work-safe _(default)_ | Hide email and cwd; show session name and model |
| Minimal               | Show only percentages and reset times           |
| Anonymous             | Hide all account/session identifiers            |

---

## 14. Notifications

Local `UserNotifications` from the app. No sound by default.

**Triggers:**

1. Session usage crosses warning threshold (80%).
2. Session usage crosses critical threshold (95%).
3. Weekly usage crosses warning threshold (80%).
4. Weekly usage crosses critical threshold (95%).
5. Session reset occurs (optional, disabled by default).
6. CLI becomes unauthenticated.
7. CLI output becomes unparsable after previously working.

**Deduplication:**

1. Notify once per threshold crossing per reset window.
2. Do not repeat warning after critical has fired.
3. Reset notification state after the corresponding reset time passes.
4. Do not notify if data is stale.

---

## 15. Settings schema

| Setting                         | Type   | Default         |
| ------------------------------- | ------ | --------------- |
| `claudeCliPath`                 | String | auto-detect     |
| `statusCommand`                 | String | `status`        |
| `statsCommand`                  | String | `stats`         |
| `pollIntervalActiveSeconds`     | Int    | `15`            |
| `pollIntervalBackgroundSeconds` | Int    | `60`            |
| `cliTimeoutSeconds`             | Int    | `5`             |
| `staleAfterSeconds`             | Int    | `180`           |
| `warningThresholdPercent`       | Double | `80`            |
| `criticalThresholdPercent`      | Double | `95`            |
| `privacyMode`                   | Enum   | `workSafe`      |
| `launchAtLogin`                 | Bool   | `false`         |
| `enableDiagnosticsRawOutput`    | Bool   | `false`         |
| `displayTimezone`               | String | system timezone |
| `enableNotifications`           | Bool   | `true`          |

Advanced settings (hidden by default):

1. Run via login shell.
2. Custom environment variables for CLI subprocess.
3. Parser mode: `auto` / `text` / `json`.
4. History retention days (default 180).
5. Debug logging level.

---

## 16. Security and privacy

1. No network calls required.
2. No analytics.
3. Raw CLI output stored only when diagnostics are explicitly enabled.
4. Email, organization, cwd, session name redacted from logs by default.
5. Preferences stored locally; no cloud sync.
6. Do not store Claude credentials.
7. Do not read or modify Claude config files except by invoking the configured CLI command.
8. Crash reports must not include raw paths or account identifiers without opt-in.

---

## 17. Accessibility

1. All progress bars must have text equivalents (`.accessibilityLabel`).
2. VoiceOver label: `"Session usage 25 percent, resets at 2:50 PM. Weekly usage 30 percent, resets June 27 at 3 PM."`.
3. Do not convey warning/critical state through color alone — pair with icon or text.
4. All popover controls keyboard navigable.
5. Support Dynamic Type where feasible in popover.

---

## 18. Error handling

| Condition         | User-facing state         | Recovery                      |
| ----------------- | ------------------------- | ----------------------------- |
| CLI not found     | `Claude CLI not found`    | Open settings; choose binary  |
| CLI timeout       | `Claude CLI timed out`    | Increase timeout or check CLI |
| Unauthenticated   | `Claude not logged in`    | Run `claude login`            |
| Parse failure     | `Could not parse output`  | Open diagnostics              |
| Permission denied | `Cannot run Claude CLI`   | Check path/permissions        |
| Empty output      | `No Claude status output` | Retry; open diagnostics       |
| Stale snapshot    | `Last updated Xm ago`     | Refresh now                   |

---

## 19. Testing

### 19.1 Parser unit tests

Cover fixtures for:

1. Provided sample output.
2. No weekly block.
3. No session block.
4. Decimal percentage.
5. Over-100 percentage.
6. Missing timezone.
7. Multiple reset date formats.
8. ANSI-colored output.
9. Wrapped session name.
10. Unauthenticated CLI output.
11. CLI error output (non-zero exit).
12. Model table with missing cost.
13. MCP field absent.
14. Empty output.
15. Unknown model name format.

### 19.2 Integration tests

1. Command runner handles success.
2. Command runner handles timeout.
3. Command runner captures stderr.
4. Snapshot writer performs atomic replace.
5. Snapshot reader handles missing file.
6. Snapshot reader handles corrupt JSON.

### 19.3 UI tests

1. Onboarding sets CLI path.
2. Manual refresh updates displayed data.
3. Privacy modes hide sensitive fields.
4. Threshold settings affect severity display.
5. Error state shows correct recovery action.
6. Menu bar icon updates to reflect severity.

---

## 20. Acceptance criteria

MVP is complete when:

1. The app can locate or configure the `claude` CLI path.
2. The app can run the configured status command with timeout handling.
3. The parser extracts session percentage, session reset, weekly percentage, and weekly reset from the provided sample.
4. The app writes a valid `current.json` snapshot atomically.
5. The popover renders setup, OK, warning, critical, stale, and error states.
6. The menu bar icon reflects the highest-severity usage state.
7. The user can manually refresh from the popover.
8. Privacy mode hides sensitive identifiers in the popover.
9. Diagnostics can copy sanitized output.

---

## 21. Open questions

1. Does the installed `claude` CLI expose stable JSON for `status`/`stats`? (Check `claude status --json`.)
2. Should the app live in the Dock as well as the menu bar, or menu bar only?
3. Should history aggregate by session ID, cwd/project, or model?
4. Should reset countdowns display rounded minutes or exact local times?
5. How aggressive should polling be on battery power?
6. Should cost and token counts be visible by default, or require opting in?
7. Should the popover show a mini chart of recent usage trend?

---

## 22. Glossary

| Term            | Meaning                                                                        |
| --------------- | ------------------------------------------------------------------------------ |
| Popover         | The SwiftUI `MenuBarExtra` `.window` view shown when clicking the icon         |
| Snapshot        | Latest parsed usage state persisted to `current.json`                          |
| Current session | Claude CLI's rolling session usage window                                      |
| Current week    | Claude CLI's weekly all-model usage window                                     |
| Stale           | Snapshot older than `staleAfterSeconds`                                        |
| Material change | Snapshot delta significant enough to require immediate UI update               |
| Severity        | `normal` / `warning` / `critical` / `overLimit` based on percentage thresholds |

---

## 23. Implementation phases

### Phase 1 — Parser and fixture harness

1. Create `ClaudeMeterCore` Swift package (no AppKit/SwiftUI dependencies).
2. Add fixture files for all known CLI output variants.
3. Implement ANSI stripping and text normalization.
4. Implement section splitting.
5. Implement usage-block parsing (percent + reset line).
6. Implement reset-time parsing with IANA timezone support.
7. Implement key-value field parsing.
8. Implement token/cost shorthand parsing.
9. Add unit tests covering all fixtures.

### Phase 2 — Data pipeline

1. Implement `ClaudeCommandRunner` (subprocess + timeout + stderr capture).
2. Implement CLI path auto-detection.
3. Implement atomic `SnapshotWriter` (`current.json`).
4. Implement `SnapshotReader`.
5. Wire parser output → snapshot model.
6. Add integration tests.

### Phase 3 — MenuBarExtra app shell

1. Create Xcode project: macOS app, `LSUIElement = YES`, no Dock icon.
2. Add `@main` `App` with `MenuBarExtra`.
3. Implement `AppState` (`ObservableObject`) as single source of truth.
4. Implement background polling `Timer` task.
5. Render popover: OK / warning / critical / stale / error states.
6. Animate menu bar icon based on severity.
7. Manual refresh button.

### Phase 4 — Notifications

1. Implement `NotificationEngine`.
2. Wire threshold crossing detection to local notifications.
3. Implement deduplication per reset window.

### Phase 5 — Settings and onboarding

1. First-run onboarding (CLI path detection / manual entry).
2. Settings panel (all settings from §15).
3. Privacy mode enforcement in popover.
4. Diagnostics view.
5. Optional launch-at-login.

### Phase 6 — WidgetKit extension (post-MVP)

1. Add App Group entitlement.
2. Move snapshot write location to App Group container.
3. Add WidgetKit extension target.
4. Implement small / medium / large widget layouts.
5. Implement timeline policy.
6. Request widget reload after material snapshot changes.

### Phase 7 — History and polish (post-MVP)

1. Add SQLite history store.
2. Add usage trend chart in popover / companion view.
3. CSV / JSON export.
4. Floating always-on-top live monitor window.
5. Advanced parser diagnostics.

---

## 24. Suggested Swift modules

```text
ClaudeMeterApp            ← @main, MenuBarExtra, AppState, polling
ClaudeMeterCore           ← Parser, data model, snapshot reader/writer (no UI deps)
ClaudeMeterUI             ← SwiftUI views, design tokens
ClaudeMeterNotifications  ← UserNotifications engine
ClaudeMeterWidgetExtension ← (Phase 6) WidgetKit target
```
