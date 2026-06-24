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
- **`JournalReader`** — used by `ClaudeAIPipeline` for cosmetic message-count labels (disk scan runs off-main).
- **`CostUsageScanner`** — scans `~/.claude/projects/**/*.jsonl` `assistant` lines for `message.usage`, dedups streaming chunks by `message.id + requestId` taking the **max** per token field (counts are cumulative, summing over-counts), prices per family via `ModelPricing` (`opus`/`haiku`/Sonnet-default substring match — estimates only), and fills `ClaudeUsageSnapshot.models` (last 7 days). `AppState.scanCostModels` runs it off-main after each poll, independent of which tier produced the rate-limit snapshot. Per-file cache (`CostUsageCache`) keyed by mtime+size; window filtering at read time.

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

`scheduleRebuildPipeline()` debounces source-toggle rebuilds (300 ms) and does not restart an active poll loop.

### Networking — `ProviderHTTP.swift`

- **All** provider HTTP goes through `ProviderHTTPClient.shared` (a `HTTPTransport`): one cookie-less ephemeral session (10 s) behind `RedirectGuardDelegate`, which drops any redirect that isn't same-origin HTTPS — credentials (`Bearer`/`Cookie`) must never be replayed off-origin or downgraded. OAuth, claude.ai, and status clients all use it.
- `HTTPRetryPolicy` (`.none` / `.transient`) gives bounded retries (idempotent methods only, honors `Retry-After`, exp backoff capped at 8 s). claude.ai + status GETs use `.transient`; OAuth keeps its own cross-poll 429 `blockedUntil` gate and uses `.none`.
- **Inject a stub `HTTPTransport`** to unit-test a client without network (see `AnthropicStatusClient(transport:)` and `TransportInjectionTests`).

### Keychain reads

- `OAuthKeychain.loadResult()` / `loadManualResult()` return `KeychainReadResult { found / missing / temporarilyUnavailable / invalid }`; `mapKeychainStatus` classifies the `OSStatus` (a locked Keychain → `temporarilyUnavailable`, never `missing`, so a transient lock doesn't drop the source). `load()`/`loadManual()` remain the `Optional` convenience wrappers.

---

## Statusline bridge

`StatuslineBridge.install()` runs on launch and each poll while statusline is enabled (idempotent + self-healing). It prepends a bash snippet to `~/.claude/settings.json` `statusLine.command` that extracts `session_id` (sanitized to `[alnum._-]`) and atomically writes stdin to `sessions/<session_id>.json`, and sets `refreshInterval: 1`.

- **Per-session files + merge** — each open Claude Code window writes its own file with the rate-limit snapshot from _its_ last API call, so staleness differs. `readData(maxAge:)` reads every fresh file and `mergePayloads` picks the freshest per window: five-hour and weekly both use **max `resets_at`** (most recent observation). Never read a single file — the meter flips between sessions otherwise.
- **Migration / self-repair** — `install()` strips _all_ leading bridge snippets (current + `legacyBridgeSnippets`) via `strippedOfAnyBridge` (loops to collapse chains) before prepending once. Migrates old single-file installs and repairs commands stacked with dozens of duplicate snippets.
- **Snippet quoting** — `session_id` is pulled with `sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p"`; keeping `sed` in double quotes avoids escaping single quotes inside the outer `bash -c '…'`. Claude Code sends compact JSON with `session_id` first. Empty/missing id → `default.json`.
- **Pipe order** — bridge must be _prepended_ (`bridge | userCmd`) and must `printf "%s" "$I"` stdin through so the user's statusline still renders.
- **`rate_limits` may be absent** — only present for Claude.ai subscribers after the first API response; `StatuslinePipeline` requires `five_hour` or `seven_day` before accepting bridge data.
- **Parser version** `statusline-1.0`; diagnostics mode check is `hasPrefix("statusline")`.

## Staleness & rolling windows

- **File mtime ≠ data freshness** — an open-but-idle session re-emits its last (stale) snapshot every second, so the file stays fresh while the numbers are hours old. The real freshness signal is `resets_at`.
- **Expired windows read 0%** — Claude's windows are _rolling_, so once `resets_at` passes the window has reset. `LimitWindow.resolved(asOf:)` encodes it (past reset → `percentUsed: 0`, `resetsAt: nil`; next reset isn't predictable so no countdown). Applied in `StatuslinePipeline.displayWindow`, menu bar, `UsageCardView`, widget, and `NotificationPolicy`. Widget timeline refreshes at `min(nextReset, now+15m)`.
- **`lastPolledAt` advances only on successful polls**; derive staleness from `snapshot.lastSuccessfulPollAt` (`staleAfterSeconds`, default 180 s, in `AppGroupConfig`).
- **Claude vs Cursor staleness** — `isStale` ORs both for menu-bar UX; Claude notifications use `claudeIsStale` only.

## OAuth usage API (Claude Code token)

- **Keychain** — `OAuthKeychain` uses Security.framework (`SecItem*`); service `Claude Code-credentials`, account `NSUserName()`. Auto creds vs app-owned manual creds (service `com.jewei.claudemeter-oauth`, account `oauthManual`).
- **`oauthMode` gate** — `OAuthPipeline` only calls the API when `oauthMode` is `auto` or `manual` (`AppGroupConfig.oauthModeKey`); empty skips to tier 3. Manual disconnect deletes the app-owned entry and clears `oauthMode`.
- **Auto refresh is in-memory only** — refreshed auto tokens are cached in `OAuthPipeline` for the session; we do **not** write back to Claude Code's Keychain entry.
- **Decode `UsageResponse`, not `[String: QuotaEntry]`** — the endpoint returns extra keys (`limits`, `spend`, `extra_usage`, nulls). `utilization` is already 0–100; don't ×100. `QuotaEntry.utilization` is optional so null/empty windows degrade to "unknown" instead of failing the whole decode.
- **Windows mapped** — `five_hour` → session, `seven_day` → `currentWeekAllModels`, `seven_day_opus` → `currentWeekOpus` (often the binding limit for Max), `extra_usage` → `ExtraUsage` (monthly overage $). All feed severity + notifications (`weeklyOpus` scope). The statusline bridge and claude.ai client parse `seven_day_opus` too.
- **Statusline can't see Opus/extra/plan** — Claude Code's statusline `rate_limits` only emits `five_hour` + `seven_day`. `seven_day_opus`, `extra_usage`, and `subscriptionType` exist **only** in the OAuth response. `OAuthPipeline.fetchEnrichment` fetches them and `AppState.oauthEnrichment` layers them onto a non-OAuth snapshot (gated on `oauthMode` being set). `extra_usage` amounts are integer **minor units** (`used_credits`/`monthly_limit` ÷ `10^decimal_places`), not dollars; `is_enabled:false` can coexist with real `used_credits` (e.g. `out_of_credits`).
- **429 backoff** — `OAuthPipeline` honors `Retry-After` (delta-seconds or HTTP-date) via an in-pipeline `blockedUntil` gate; while blocked it skips the API and serves the fallback (default 60 s). Sends `User-Agent: claude-code/<ver>`.
- **`expiresAt` is integer milliseconds** in the Keychain JSON; parse via `NSNumber`/`Int`/`Double`. Refresh when within 60 s of expiry.
- **Token refresh** — `POST https://console.anthropic.com/v1/oauth/token`, `grant_type=refresh_token`, client id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`; usage calls send `anthropic-beta: oauth-2025-04-20`. Ephemeral `URLSession`, no cookies, 10 s timeout.

## claude.ai API

- **Manual Cookie needs an ephemeral session** — `URLSession.shared` drops/overrides the `Cookie` header; `ClaudeAIUsageClient` uses a private ephemeral session (`httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`).
- **Keychain** — `ClaudeAIKeychain`, service `com.jewei.claudemeter`, accounts `claudeai.sessionKey` and `claudeai.orgId`. Session key is a browser cookie; never log it.
- **Org auto-resolve** — Org ID is optional in Settings; blank → `ClaudeAIUsageClient.resolveOrgId(sessionKey:)` calls `GET /api/organizations` and `selectOrganization` prefers the org with the `chat` capability (not blindly index 0), falling back to the first. Manual UUID paste still works.
- **Browser cookie import** — `BrowserCookieImporter.importClaudeSessionKey()` reads the `sessionKey` cookie from Chromium browsers (Chrome/Brave/Edge/Arc/Chromium), Firefox, and Safari, then org auto-resolve fills the rest. Chromium decrypt: **v10** = PBKDF2-SHA1(pw,"saltysalt",1003,16) + AES-128-CBC (IV = 16×0x20); **v20** = AES-256-GCM (`v20`‖nonce12‖ct‖tag16) with a PBKDF2 32-byte key — **best-effort/unverified for v20 app-bound; iterate from device output**. Plaintext carries a 32-byte domain-hash prefix, so `extractSessionKey` locates the `sk-ant-` token. Reads via `sqlite3` + `security`; first Keychain access prompts the user. Cookie DBs are read `-readonly`, falling back to a `file:…?immutable=1` URI when the browser holds a WAL lock (Firefox while running blocks `-readonly`; spaces in the path are %20-encoded). Verified on-device: Chrome/Brave (v10), Firefox, Safari all import; v20 still unconfirmed (no v20 cookie seen yet). Never log the value (it's a credential).
- **Failure handling** — transient errors fall back to `CachedSnapshotPipeline` and surface a `ParseWarning` (`field: "claude.ai API"`); auth failures (401/403) are fatal and do **not** fall back.

## Cursor usage (opt-in)

- **Separate from Claude pipeline** — `cursorSourceEnabled` defaults `false`; polled in parallel via `pollCursor`, not part of `makePipeline()`.
- **Token read-only** — `CursorTokenStore` reads `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (batched `sqlite3 -readonly`, 10 s timeout) with Keychain fallback (`cursor-access-token` / `cursor-refresh-token`). Never writes back.
- **API** — unofficial Connect-RPC on `api2.cursor.sh` (`GetCurrentPeriodUsage`); may break without notice. `totalPercentUsed` is authoritative over raw spend/limit.
- **Refresh** — in-memory only for the app session; rotated refresh tokens are cached in `CursorUsageProvider`. Open Cursor if refresh fails.
- **UX** — `cursorError` surfaces in popover/settings/diagnostics; menu bar severity includes Cursor when enabled. Not in widget/notifications yet.

## Notifications

- **`NotificationEngine` is an actor**; only processes non-stale Claude snapshots; thresholds via `AppGroupConfig.currentThresholds(defaults:)`.
- **Dedup** is one per `(scope, level, resetsAt-epoch)`; critical suppresses warning. When `resetsAt` is nil, falls back to the start of the next local day. `markFired` only after `UNUserNotificationCenter.add` succeeds. No sound.

## Widget / App Group

- **Sandboxed** — never fall back to `applicationSupport()`; read `SnapshotStore.appGroup()` only and return `nil` gracefully.
- **macOS 26 SDK** — `Widget`/`WidgetBundle` live in `SwiftUI`; the bundle file needs `import SwiftUI` even though it uses `WidgetKit` types.
- **Design tokens aren't shared across targets** — duplicate `Color(hex:)` as `Color(widgetHex:)` in the widget. Intentional.

## Swift 6 concurrency

- `DateFormatter` / `ISO8601DateFormatter` / `NumberFormatter` aren't `Sendable` — create per call, or `nonisolated(unsafe) static let` behind serial access.
- Heavy poll work (`pipeline.poll`, `CursorUsageProvider.fetchUsage`, `JournalReader`) runs in `Task.detached`; only published state updates on `@MainActor`.
- `queue.sync` inside `queue.async` on the same serial queue deadlocks — async wrappers call queue-local helpers directly.
- `Task.detached` from `@MainActor` (e.g. `installStatuslineBridgeIfNeeded`) must capture only `Sendable` state.

## Diagnostics sanitizer

Always sanitize before logging or copying. `DiagnosticsSanitizer.sanitize` redacts emails, home paths (`/Users/<name>`), UUIDs, `sk-ant-*` / `oidc-*` tokens, JWTs (`eyJ…`), `Bearer …`, `sessionKey=…`, labeled token fields (`access[_]token`, `refresh[_]token`), and labeled CLI fields (`Session name:`, `Organization:`, `Cwd:`, `Email:`, `Session id:`).

---

## Known gaps

- No explicit `fsync` on snapshot atomic writes.
- No in-app notice when the claude.ai session key (logout / ~90 days) or the OAuth access token expires.
- `default.json` collides if multiple sessions ever lack a `session_id` (rare — Claude Code always sends one).
- Cursor usage is not in the widget or notification engine yet.
