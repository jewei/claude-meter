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
- **Pipeline protocol** — `ClaudeMeterPipeline` (`func poll(now: Date) async throws -> ParseResult`). `AppState.pipeline` is typed as `any ClaudeMeterPipeline`.
- **Project file** — `project.pbxproj` is hand-maintained; no xcodegen. Every new file needs a `PBXFileReference`, a `PBXBuildFile`, a group child entry, and a Sources/Frameworks build phase entry. Use consistent 24-char hex UUIDs throughout.

### Data-source fallback order

When the statusline bridge is fresh, only tier 1 is used. When stale, tiers 2–3 run (rate-limited by `statuslineFallbackCooldownSeconds`). Each tier falls through to the next on failure.

| Priority | Pipeline                 | Source                                                                               |
| -------- | ------------------------ | ------------------------------------------------------------------------------------ |
| 1        | `StatuslinePipeline`     | `StatuslineBridge` → `~/.claude-meter/statusline.json`                               |
| 2        | `OAuthPipeline`          | `GET https://api.anthropic.com/api/oauth/usage` · `Authorization: Bearer <token>`    |
| 3        | `ClaudeAIPipeline`       | `GET https://claude.ai/api/organizations/{orgId}/usage` · `Cookie: sessionKey=<key>` |
| —        | `CachedSnapshotPipeline` | Terminal fallback: last persisted snapshot marked stale                              |

Factory in `AppState.makePipeline`:

```
StatuslinePipeline
  └─ OAuthPipeline
       └─ ClaudeAIPipeline (if session key + org ID in Keychain)
            └─ CachedSnapshotPipeline
```

`StatuslineBridge.install()` runs on app launch (idempotent). It prepends a bash snippet to `~/.claude/settings.json` `statusLine.command` that atomically writes stdin JSON to `~/.claude-meter/statusline.json`, and sets `refreshInterval: 1` so Claude Code re-runs the command every second while open.

`StatsCachePipeline` / `StatsCacheReader` / `JournalReader` remain in the package for tests and SwiftUI previews but are **not** in the production poll chain.

Removed: SQLite `HistoryStore`, `HistoryView`, `MiniMonitorView`.

---

## Common mistakes

### Swift 6 concurrency

- **`ISO8601DateFormatter` is not `Sendable`** — mark `static let` formatters `nonisolated(unsafe)` when all access is protected by a serial queue. Same applies to `DateFormatter`, `NumberFormatter`, etc.
- **`DispatchQueue.sync` doesn't support `throws`** — use `Result { try work() }` captured in a `var`, then `result!.get()`. This is the `synchronized<T>` helper pattern.
- **`queue.sync` inside `queue.async` = deadlock** — async wrappers must call private queue-local helpers directly, not go through a `synchronized` wrapper which calls `queue.sync` again.
- **`actor` deinit** — deinit is non-isolated; accessing actor-stored `OpaquePointer` in deinit is technically a concurrency violation. Use `final class @unchecked Sendable` + serial `DispatchQueue` for C resource wrappers like SQLite.
- **`Task.detached` for fire-and-forget work from `@MainActor`** — the work target must be `Sendable`.

### Widget / App Group

- **Widget is sandboxed** — never fall back to `applicationSupport()` in widget code; the sandbox blocks it. Read from `SnapshotStore.appGroup()` only; return `nil` gracefully when unavailable.
- **macOS 26 SDK** — `Widget` and `WidgetBundle` protocols moved into `SwiftUI` module; `ClaudeMeterWidgetBundle.swift` needs `import SwiftUI` even though it uses `WidgetKit` types.
- **Design tokens can't be shared between app and widget targets** — widget target can't import app-target Swift files. Duplicate the `Color(hex:)` extension as `Color(widgetHex:)` in the widget. Intentional and acceptable.

### Statusline bridge

- **Install is idempotent** — `StatuslineBridge.install()` skips command rewrite when the bridge marker is already present, but still patches `refreshInterval: 1` on existing installs.
- **Pipe order matters** — the bridge snippet must be _prepended_ (`bridge | existingCmd`) so it captures stdin before the user's statusline script runs.
- **`rate_limits` may be absent** — only present for Claude.ai subscribers after the first API response. `StatuslinePipeline` requires `five_hour` or `seven_day` before accepting bridge data.
- **Parser versions** — statusline snapshots use `parserVersion: "statusline-1.0"`; diagnostics mode string checks `hasPrefix("statusline")`.

### OAuth usage API (Claude Code token)

- **Keychain account is `$(whoami)`** — Claude Code stores credentials under service `Claude Code-credentials`, account = current username. Always pass `-a` to `security find-generic-password`; without it macOS may return the wrong entry (e.g. MCP OAuth data under account `unknown`).
- **`OAuthKeychain` uses `/usr/bin/security` subprocess** — not the Security framework. Account name comes from `NSUserName()`.
- **`oauthMode` UserDefaults gate** — `OAuthPipeline` only calls the API when `oauthMode` is `"auto"` or `"manual"`. Empty means skip straight to tier 3. Disconnect clears `oauthMode`; manual disconnect also deletes the app-owned Keychain entry.
- **Decode `UsageResponse`, not `[String: QuotaEntry]`** — the usage endpoint returns many extra keys (`limits`, `spend`, `extra_usage`, nulls). Decoding the full object as a string-keyed quota map fails with "The data couldn't be read because it is missing."
- **`expiresAt` in Keychain JSON is integer milliseconds** — parse via `NSNumber` / `Int` / `Double`, not `as? Double` alone.
- **Token refresh** — `POST https://console.anthropic.com/v1/oauth/token` with `grant_type=refresh_token` and client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e`. Request header `anthropic-beta: oauth-2025-04-20` on usage calls.
- **URLSession** — ephemeral config with `httpShouldSetCookies = false` and `httpCookieAcceptPolicy = .never` (same pattern as `ClaudeAIUsageClient`).

### claude.ai API data source

- **URLSession.shared interferes with manual Cookie headers** — use a custom `URLSessionConfiguration.ephemeral` with `httpShouldSetCookies = false` and `httpCookieAcceptPolicy = .never`. `ClaudeAIUsageClient` has a `private static let session` that does this.
- **Session key is a browser cookie** — stored in macOS Keychain via `ClaudeAIKeychain` (service `com.jewei.claudemeter`, accounts `claudeai.sessionKey` and `claudeai.orgId`). Never log it.
- **Transient API failure** — `ClaudeAIPipeline` falls back to `CachedSnapshotPipeline` and surfaces the error as a `ParseWarning`. Auth failures (401) do **not** fall back.
- **Org ID must be pasted manually** — if user has multiple orgs, auto-detect may pick the wrong one.

### stats-cache.json (legacy, not in production pipeline)

- **`claude status` is a TUI, not a plain-text command** — never run it as a subprocess to parse output.
- **`stats-cache.json` uses local calendar day strings** — use `DateFormatter` with the current timezone, not `ISO8601DateFormatter` (UTC default).
- **`LimitWindow.rawValueText`** — carries "N msgs" when `percentUsed` is nil.

### Parser & pipeline (legacy — kept for tests only)

- **`ClaudeOutputParser` — pass `now` per call, not at init** — long-running sessions resolve reset times against launch time if `now` is stored at construction.
- **ANSI strip before auth detection** — run `ANSIStripper.strip` on raw output before checking `isUnauthenticated`.

### Staleness & UI

- **`lastPolledAt` must not advance on failed polls** — only advance on successful snapshot updates; derive staleness from `snapshot.lastSuccessfulPollAt`.
- **Two staleness concepts** — `staleAfterSeconds` (UI display) vs `statuslineStalenessSeconds` (when to leave tier 1). API fallback cooldown (`statuslineFallbackCooldownSeconds`, min 60 s) limits tier 2/3 poll frequency.

### Notifications

- **Notification dedup with nil `resetsAt`** — fall back to a daily anchor (start of today UTC) so notifications still fire on severity escalation.

---

## Diagnostics sanitizer

Always sanitize before logging or copying to clipboard:

- Email addresses → `[redacted]`
- Home directory paths (`/Users/<name>/…`) → `/Users/[redacted]/…`
- Labeled fields in CLI output (`Session name:`, `Organization:`, `Cwd:`, `Email:`, `Session id:`) → value replaced with `[redacted]`

---

## Settings (current)

| Tab           | Setting                | Key                                 | Default             |
| ------------- | ---------------------- | ----------------------------------- | ------------------- |
| Data          | OAuth mode             | `oauthMode`                         | `""` (disconnected) |
| Data          | Statusline stale after | `statuslineStalenessSeconds`        | 120s                |
| Data          | API fallback cooldown  | `statuslineFallbackCooldownSeconds` | 60s                 |
| Data          | Session key            | Keychain (`claudeai.sessionKey`)    | —                   |
| Data          | Org ID                 | Keychain (`claudeai.orgId`)         | —                   |
| Data          | Poll (popover open)    | `pollIntervalActiveSeconds`         | 15s                 |
| Data          | Poll (background)      | `pollIntervalBackgroundSeconds`     | 60s                 |
| Data          | Mark stale after       | `staleAfterSeconds`                 | 180s                |
| Display       | Warning threshold      | `warningThresholdPercent`           | 80%                 |
| Display       | Critical threshold     | `criticalThresholdPercent`          | 95%                 |
| Notifications | Enable                 | `enableNotifications`               | true                |
| Advanced      | Launch at login        | `launchAtLogin`                     | false               |

Removed settings (no longer in UI): `statsCachePath`, `dailyMessageLimit`, `weeklyMessageLimit`, `journalProjectsPath`, `privacyMode`, CLI path, CLI timeout, raw output toggle, `historyRetentionDays`.

---

## Deferred / known gaps

- `rebuildPipeline()` fires on every settings keystroke — needs debounce
- Notification `markFired` called before delivery confirmation
- Explicit fsync on snapshot atomic writes
- Widget `resetText` uses `Date()` instead of `entry.date`
- Session key expires when user logs out of claude.ai or after ~90 days — no in-app expiry notification yet
- OAuth access token expiry — no in-app notification when Claude Code credentials expire
- Duplicate bridge snippets can accumulate in `statusLine.command` if install logic regresses — install checks for `.claude-meter/statusline.json` marker only once at the start of the command string
