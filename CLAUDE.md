# Claude Meter — Development Notes

## Build & test

```bash
# Full app build (no signing required for compilation checks)
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO

# Core library tests
swift test --package-path ClaudeMeterCore
```

App Group entitlement (`com.apple.security.application-groups`) requires a real provisioning profile to _run_; `CODE_SIGNING_ALLOWED=NO` is sufficient for compilation.

---

## Architecture

- **Main app** — `@MainActor final class AppState`, `MenuBarExtra` with `.window` style, `LSUIElement = YES` (no Dock icon)
- **Core library** — `ClaudeMeterCore` Swift package, no AppKit/SwiftUI deps, Swift 6 strict concurrency
- **Widget** — sandboxed `ClaudeMeterWidgetExtension`; reads from App Group container only (no `applicationSupport()` fallback)
- **Shared container** — `group.com.jewei.claudemeter`; `AppGroupConfig` centralises the suite name and syncs display settings
- **Data source (primary)** — `ClaudeAIPipeline` calls `GET https://claude.ai/api/organizations/{orgId}/usage` with a session key stored in Keychain (`ClaudeAIKeychain`). Returns exact `five_hour.utilization` and `seven_day.utilization` percentages with `resets_at` timestamps.
- **Data source (fallback)** — `StatsCachePipeline` reads `~/.claude/stats-cache.json` via `StatsCacheReader` + real-time JSONL counts via `JournalReader`. Used when no Keychain credentials are present, or when the API call fails.
- **Pipeline protocol** — `ClaudeMeterPipeline` (`func poll(now: Date) async throws -> ParseResult`). Both `ClaudeAIPipeline` and `StatsCachePipeline` conform. `AppState.pipeline` is typed as `any ClaudeMeterPipeline`.
- **Project file** — `project.pbxproj` is hand-maintained; no xcodegen. Every new file needs a `PBXFileReference`, a `PBXBuildFile`, a group child entry, and a Sources/Frameworks build phase entry. Use consistent 24-char hex UUIDs throughout.

---

## Common mistakes

### Swift 6 concurrency

- **`ISO8601DateFormatter` is not `Sendable`** — mark `static let` formatters `nonisolated(unsafe)` when all access is protected by a serial queue. Same applies to `DateFormatter`, `NumberFormatter`, etc.
- **`DispatchQueue.sync` doesn't support `throws`** — use `Result { try work() }` captured in a `var`, then `result!.get()`. This is the `synchronized<T>` helper pattern used in `HistoryStore`.
- **`queue.sync` inside `queue.async` = deadlock** — async export wrappers (`exportCSVAsync`, `exportJSONAsync`, `recordCountAsync`) must call private queue-local helpers directly, not go through the `synchronized` wrapper which calls `queue.sync` again.
- **`actor` deinit** — deinit is non-isolated; accessing actor-stored `OpaquePointer` in deinit is technically a concurrency violation. Use `final class @unchecked Sendable` + serial `DispatchQueue` for C resource wrappers like SQLite.
- **`Task.detached` for fire-and-forget writes from `@MainActor`** — e.g., `Task.detached(priority: .utility) { try? store.append(record) }`. The store must be `Sendable`.

### Widget / App Group

- **Widget is sandboxed** — never fall back to `applicationSupport()` in widget code; the sandbox blocks it. Read from `SnapshotStore.appGroup()` only; return `nil` gracefully when unavailable.
- **macOS 26 SDK** — `Widget` and `WidgetBundle` protocols moved into `SwiftUI` module; `ClaudeMeterWidgetBundle.swift` needs `import SwiftUI` even though it uses `WidgetKit` types.
- **Design tokens can't be shared between app and widget targets** — widget target can't import app-target Swift files. Duplicate the `Color(hex:)` extension as `Color(widgetHex:)` in the widget. Intentional and acceptable.

### claude.ai API data source

- **URLSession.shared interferes with manual Cookie headers** — use a custom `URLSessionConfiguration.ephemeral` with `httpShouldSetCookies = false` and `httpCookieAcceptPolicy = .never`. `ClaudeAIUsageClient` has a `private static let session` that does this.
- **Session key is a browser cookie** — stored in macOS Keychain via `ClaudeAIKeychain` (service `com.jewei.claudemeter`, accounts `claudeai.sessionKey` and `claudeai.orgId`). Never log it.
- **API failure falls back silently** — `ClaudeAIPipeline` catches any error and delegates to `StatsCachePipeline`, surfacing the API error as a `ParseWarning` so the UI still shows data.
- **Org ID from auto-detect may be wrong** — if user has multiple orgs (personal + team), `/api/organizations` returns all. The Settings "Auto-detect" is removed; user must paste the correct UUID manually.

### stats-cache.json data source

- **`claude status` is a TUI, not a plain-text command** — running it as a subprocess opens the full interactive terminal UI. Never try to parse its output as plain text.
- **`stats-cache.json` uses local calendar day strings** — dates like `"2026-06-21"` are in the user's local timezone. Use `DateFormatter` with the current timezone, not `ISO8601DateFormatter` which defaults to UTC.
- **Cache may lag behind the live session** — Claude Code updates the file when sessions end or at session start. `JournalReader` supplements with real-time JSONL counts.
- **`LimitWindow.rawValueText`** — carries "N msgs" for the UI to display when `percentUsed` is nil (no API, no plan limits set). `UsageCardView` and `MiniMonitorView` fall back to this instead of showing "—".

### Parser & pipeline (legacy — SnapshotPipeline / ClaudeOutputParser kept for tests only)

- **`ClaudeOutputParser` — pass `now` per call, not at init** — if you store `now` at construction time, long-running sessions resolve reset times against launch time.
- **ANSI strip before auth detection** — run `ANSIStripper.strip` on raw output before checking `isUnauthenticated`. The CLI may emit ANSI escape codes around error text that break plain-text pattern matching.

### History store (SQLite)

- **`ORDER BY created_at ASC LIMIT N` drops newest rows** — when capping results, use `ORDER BY created_at DESC LIMIT N` then reverse the array, so a limit of 5000 keeps the most recent 5000 records, not the oldest 5000.
- **`Date.distantPast` with `ISO8601DateFormatter`** — formats as `"0001-01-01T00:00:00Z"`, which works fine for string comparison in SQLite since ISO8601 strings sort lexicographically.
- **`JSONEncoder` omits `nil` optionals** — it does _not_ encode `nil` as `null`; the key is simply absent. Don't assert `json.contains("null")` for a nil optional field.
- **Prune on append, not just on open** — call `pruneToRetentionCutoff()` inside `append`'s transaction so the DB stays bounded even if the process runs for weeks without restart.

### Staleness & UI

- **`lastPolledAt` must not advance on failed polls** — updating it on every attempt (success or failure) causes the footer to show "Just updated" even when the displayed data is stale. Only advance `lastPolledAt` on successful snapshot updates; derive staleness from `snapshot.lastSuccessfulPollAt`.

### Notifications

- **Notification dedup with nil `resetsAt`** — the dedup key uses `resetsAt` as the window anchor; if the parser can't extract a reset time, fall back to a daily anchor (start of today UTC) so notifications still fire on severity escalation rather than being silently suppressed.

---

## Diagnostics sanitizer

Always sanitize before logging or copying to clipboard:

- Email addresses → `[redacted]`
- Home directory paths (`/Users/<name>/…`) → `/Users/[redacted]/…`
- Labeled fields in CLI output (`Session name:`, `Organization:`, `Cwd:`, `Email:`, `Session id:`) → value replaced with `[redacted]`

---

## Settings (current)

| Tab           | Setting             | Key                             | Default |
| ------------- | ------------------- | ------------------------------- | ------- |
| Data          | Session key         | Keychain                        | —       |
| Data          | Org ID              | Keychain                        | —       |
| Data          | Poll (popover open) | `pollIntervalActiveSeconds`     | 15s     |
| Data          | Poll (background)   | `pollIntervalBackgroundSeconds` | 60s     |
| Data          | Mark stale after    | `staleAfterSeconds`             | 180s    |
| Display       | Warning threshold   | `warningThresholdPercent`       | 80%     |
| Display       | Critical threshold  | `criticalThresholdPercent`      | 95%     |
| Notifications | Enable              | `enableNotifications`           | true    |
| Advanced      | Launch at login     | `launchAtLogin`                 | false   |
| Advanced      | History retention   | `historyRetentionDays`          | 180d    |

Removed settings (no longer in UI): `statsCachePath`, `dailyMessageLimit`, `weeklyMessageLimit`, `journalProjectsPath`, `privacyMode`, CLI path, CLI timeout, raw output toggle.

---

## Deferred / known gaps

- `rebuildPipeline()` fires on every settings keystroke — needs debounce
- Notification `markFired` called before delivery confirmation
- Explicit fsync on snapshot atomic writes
- Widget `resetText` uses `Date()` instead of `entry.date`
- History `sessionPercent` / `weekPercent` will be `nil` for stats-cache fallback with no plan limits — history chart shows empty lines
- `StatsCacheReader` uses local calendar timezone for date matching — if Claude Code uses UTC dates in a future version, today's data may not be found
- Session key expires when user logs out of claude.ai or after ~90 days — no in-app expiry notification yet
