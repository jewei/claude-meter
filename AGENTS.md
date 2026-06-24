# Claude Meter — Development Notes

Concise, non-obvious gotchas. Full behaviour/spec lives in `SPECS.md`.

## Build & test

```bash
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO  # compile check
swift test --package-path ClaudeMeterCore                                    # core tests
```

The App Group entitlement needs a real provisioning profile to _run_;
`CODE_SIGNING_ALLOWED=NO` is enough to _compile_.

---

## Architecture

- **Main app** — `@MainActor final class AppState`; `MenuBarExtra` `.window` style; `LSUIElement = YES` (no Dock icon).
- **Core** — `ClaudeMeterCore` Swift package, no AppKit/SwiftUI, Swift 6 strict concurrency.
- **Widget** — sandboxed `ClaudeMeterWidgetExtension`; reads `SnapshotStore.appGroup()` only.
- **Shared container** — `group.com.jewei.claudemeter`; `AppGroupConfig` owns the suite name and syncs display settings.
- **Pipeline protocol** — `ClaudeMeterPipeline.poll(now:) async throws -> ParseResult`; `AppState.pipeline` is `any ClaudeMeterPipeline`.
- **`project.pbxproj` is hand-maintained** (no xcodegen). A new file needs a `PBXFileReference`, `PBXBuildFile`, group child entry, and build-phase entry, all with consistent 24-char hex UUIDs.
- **Legacy kept for tests/previews only** (not in the poll chain): `StatsCachePipeline`, `StatsCacheReader`, `JournalReader`, `ClaudeOutputParser`, `CommandRunner`, `CLIPathDetector`, `ANSIStripper`.

### Data-source fallback order

Tier 1 is used while the statusline bridge is fresh; when stale, tiers 2–3 run (rate-limited). Each tier falls through to the next on failure.

| Priority | Pipeline                 | Source                                                                               |
| -------- | ------------------------ | ------------------------------------------------------------------------------------ |
| 1        | `StatuslinePipeline`     | `StatuslineBridge` → `~/.claude-meter/sessions/<session_id>.json` (merged)            |
| 2        | `OAuthPipeline`          | `GET https://api.anthropic.com/api/oauth/usage` · `Authorization: Bearer <token>`    |
| 3        | `ClaudeAIPipeline`       | `GET https://claude.ai/api/organizations/{orgId}/usage` · `Cookie: sessionKey=<key>` |
| —        | `CachedSnapshotPipeline` | Terminal fallback: last persisted snapshot, marked stale                             |

`AppState.makePipeline` builds bottom-up, skipping disabled sources:
`StatuslinePipeline → OAuthPipeline → ClaudeAIPipeline (needs Keychain creds) → CachedSnapshotPipeline`.

Poll cadence and the statusline staleness / API-fallback cooldown are all **hardcoded 60 s** (not user settings). Settings & persisted keys: see `SPECS.md` §2.7 and §8.

---

## Statusline bridge

`StatuslineBridge.install()` runs on launch (idempotent + self-healing). It prepends a bash snippet to `~/.claude/settings.json` `statusLine.command` that extracts `session_id` and atomically writes stdin to `sessions/<session_id>.json`, and sets `refreshInterval: 1`.

- **Per-session files + merge** — each open Claude Code window writes its own file with the rate-limit snapshot from _its_ last API call, so staleness differs. `readData(maxAge:)` reads every fresh file and `mergePayloads` picks the freshest per window: five-hour = **max `resets_at`** (most recent observation), weekly = **max `used_percentage`** (monotonic). Never read a single file — the meter flips between sessions otherwise.
- **Migration / self-repair** — `install()` strips _all_ leading bridge snippets (current + `legacyBridgeSnippets`) via `strippedOfAnyBridge` (loops to collapse chains) before prepending once. Migrates old single-file installs and repairs commands stacked with dozens of duplicate snippets.
- **Snippet quoting** — `session_id` is pulled with `sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p"`; keeping `sed` in double quotes avoids escaping single quotes inside the outer `bash -c '…'`. Claude Code sends compact JSON with `session_id` first. Empty/missing id → `default.json`.
- **Pipe order** — bridge must be _prepended_ (`bridge | userCmd`) and must `printf "%s" "$I"` stdin through so the user's statusline still renders.
- **`rate_limits` may be absent** — only present for Claude.ai subscribers after the first API response; `StatuslinePipeline` requires `five_hour` or `seven_day` before accepting bridge data.
- **Parser version** `statusline-1.0`; diagnostics mode check is `hasPrefix("statusline")`.

## Staleness & rolling windows

- **File mtime ≠ data freshness** — an open-but-idle session re-emits its last (stale) snapshot every second, so the file stays fresh while the numbers are hours old. The real freshness signal is `resets_at`.
- **Expired windows read 0%** — Claude's windows are _rolling_, so once `resets_at` passes the window has reset. `LimitWindow.resolved(asOf:)` encodes it (past reset → `percentUsed: 0`, `resetsAt: nil`; next reset isn't predictable so no countdown). Applied in `StatuslinePipeline.displayWindow` (severity + notifications) and at the view layer (`UsageCardView`, widget `WindowRow`). Widget timeline refreshes at `min(nextReset, now+15m)`.
- **`lastPolledAt` advances only on successful polls**; derive staleness from `snapshot.lastSuccessfulPollAt` (`staleAfterSeconds`, default 180 s, in `AppGroupConfig`).

## OAuth usage API (Claude Code token)

- **Keychain** — `OAuthKeychain` uses Security.framework (`SecItem*`); service `Claude Code-credentials`, account `NSUserName()`. Auto creds vs app-owned manual creds (service `com.jewei.claudemeter-oauth`, account `oauthManual`).
- **`oauthMode` gate** — `OAuthPipeline` only calls the API when `oauthMode` is `auto` or `manual`; empty skips to tier 3. Manual disconnect deletes the app-owned entry and clears `oauthMode`.
- **Decode `UsageResponse`, not `[String: QuotaEntry]`** — the endpoint returns extra keys (`limits`, `spend`, `extra_usage`, nulls). `utilization` is already 0–100; don't ×100.
- **`expiresAt` is integer milliseconds** in the Keychain JSON; parse via `NSNumber`/`Int`/`Double`. Refresh when within 60 s of expiry.
- **Token refresh** — `POST https://console.anthropic.com/v1/oauth/token`, `grant_type=refresh_token`, client id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`; usage calls send `anthropic-beta: oauth-2025-04-20`. Ephemeral `URLSession`, no cookies, 10 s timeout.

## claude.ai API

- **Manual Cookie needs an ephemeral session** — `URLSession.shared` drops/overrides the `Cookie` header; `ClaudeAIUsageClient` uses a private ephemeral session (`httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`).
- **Keychain** — `ClaudeAIKeychain`, service `com.jewei.claudemeter`, accounts `claudeai.sessionKey` and `claudeai.orgId`. Session key is a browser cookie; never log it. Org ID is pasted manually (auto-detect may pick the wrong org).
- **Failure handling** — transient errors fall back to `CachedSnapshotPipeline` and surface a `ParseWarning` (`field: "claude.ai API"`); auth failures (401/403) are fatal and do **not** fall back.

## Notifications

- **`NotificationEngine` is an actor**; only processes non-stale snapshots; thresholds via `AppGroupConfig.currentThresholds(defaults:)`.
- **Dedup** is one per `(scope, level, resetsAt-epoch)`; critical suppresses warning. When `resetsAt` is nil, falls back to the start of the next local day. `markFired` only after `UNUserNotificationCenter.add` succeeds. No sound.

## Widget / App Group

- **Sandboxed** — never fall back to `applicationSupport()`; read `SnapshotStore.appGroup()` only and return `nil` gracefully.
- **macOS 26 SDK** — `Widget`/`WidgetBundle` live in `SwiftUI`; the bundle file needs `import SwiftUI` even though it uses `WidgetKit` types.
- **Design tokens aren't shared across targets** — duplicate `Color(hex:)` as `Color(widgetHex:)` in the widget. Intentional.

## Swift 6 concurrency

- `DateFormatter` / `ISO8601DateFormatter` / `NumberFormatter` aren't `Sendable` — create per call, or `static let` + `nonisolated(unsafe)` behind serial access.
- `queue.sync` inside `queue.async` on the same serial queue deadlocks — async wrappers call queue-local helpers directly.
- `Task.detached` from `@MainActor` (e.g. `installStatuslineBridgeIfNeeded`) must capture only `Sendable` state.

## Diagnostics sanitizer

Always sanitize before logging or copying. `DiagnosticsSanitizer.sanitize` redacts emails, home paths (`/Users/<name>`), UUIDs, `sk-ant-*` / `oidc-*` tokens, `Bearer …`, `sessionKey=…`, labeled token fields (`access[_]token`, `refresh[_]token`), and labeled CLI fields (`Session name:`, `Organization:`, `Cwd:`, `Email:`, `Session id:`).

---

## Known gaps

- `rebuildPipeline()` fires on every settings keystroke — needs debounce.
- No explicit `fsync` on snapshot atomic writes.
- No in-app notice when the claude.ai session key (logout / ~90 days) or the OAuth access token expires.
- `default.json` collides if multiple sessions ever lack a `session_id` (rare — Claude Code always sends one).
