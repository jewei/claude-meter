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
- **`CostUsageScanner`** — scans `assistant` lines for `message.usage` across **every discovered config dir's `projects/`** (`projectsPaths:`, deduped by resolved path — cost is additive across accounts; one unreadable root `continue`s instead of zeroing the union; the single-path `projectsPath:` init stays as a shim). Dedups streaming chunks by `message.id + requestId` (or line index when ids are absent) taking the **max** per token field (counts are cumulative, summing over-counts), prices per family via `ModelPricing` (`opus`/`haiku`/Sonnet-default substring match — estimates only), and fills `ClaudeUsageSnapshot.models` (last 7 days, one unioned total). Files >8 MB are tail-read (4 MB); `CostUsageResult.isPartialEstimate` surfaces incomplete totals. Per-file cache (`CostUsageCache`) keyed by mtime+size with LRU cap (512); window filtering at read time. `JournalReader` unions roots the same way.
- **`ActivityScanner`** — sibling scanner for the popover activity heatmap: a `7×24` grid (`counts[weekday][hour]`, **weekday 0 = Monday … 6 = Sunday** via `(Calendar.weekday + 5) % 7`; hour in **local** time) of assistant-message counts over the last 30 days. Dedups streaming chunks by `message.id` **within each file** (counts each message once). Shares the same root-walk + tail-read behavior as `CostUsageScanner` but has **no cache** — it runs **on demand** (`AppState.loadActivityHeatmap`, off-main) when the user taps the cost card, not every poll. Not wired into `makePipeline`.

### Playful UI / energy design

- **Design system** lives in `PlayfulTheme.swift` (adaptive cream palette, `PFont` Fredoka/Nunito roles, energy semantics, chunky-3D `ViewModifier`s) and `PlayfulComponents.swift` (`ActivityRingsView`, `AccountRingCard`, `HeroSummary`, `ColorSlider`). `DESIGN.md` is the spec.
- **Energy framing** — the UI shows **energy remaining** (`percentLeft = 100 − percentUsed`; rings/bars *deplete*), but severity still keys off the existing `UsageThresholds` (% used: warning 80 / critical 95), so the menu-bar dot, ring colors, notifications, and the user's threshold settings all stay consistent. Don't reframe thresholds as "% left" — only the *display* is inverted.
- **Fonts** — real Fredoka + Nunito ship under `ClaudeMeter/Fonts/` (OFL, static per-weight TTFs), wired as a **folder reference** into both the app and widget Resources phases with `ATSApplicationFontsPath = Fonts`. `PFont` (app) / widget-local `WFont` map a `Font.Weight` to an exact PostScript face (`Fredoka-SemiBold`, `Nunito-ExtraBold`, …) — no fragile variable-font `.weight()`. The **menu bar keeps SF system** (metrics); the **app icon** is a SwiftUI-drawn green bolt (regenerate via the icon-gen approach, all 10 `AppIcon` sizes).
- **Per-account name + plan** — `AppGroupConfig.accountNames` / `accountPlans` (keyed by account key, e.g. `claude-tech-oneone`) are **user-set** in Settings → Data → Statusline Bridge, because plan/email are OAuth single-slot (one shared Keychain login; no per-dir creds). The popover reads them: `name override ?? friendlyName(label)`, `plan override ?? OAuth plan (active account only)`.
- **Menu bar** = `AppState.severity` + `menuBarLimitSets`: the pinned account when `AppGroupConfig.menuBarAccount` is set, else nearest-limit across all accounts. The displayed *number* is gated by `AppGroupConfig.menuBarWindow` (`nearest`/`5h`/`7d`/`both`): `nearest` keeps the min energy-left across all windows/accounts; `5h`/`7d`/`both` show the active-or-pinned account's window(s) with a suffix (`AppState.menuBarActiveLimits`). **The dot color always keys off `severity` across all windows** — so a single-window number can differ from the dot, by design. **Settings** uses a custom bold tab bar (not native `TabView`); window title via `SettingsWindowAccessor`.
- **Appearance settings** — `AppGroupConfig.cardStyle` (rings|bars, popover-only — widget stays rings), `progressionMode` (left|used), `menuBarAccount`, and `menuBarWindow` live in the **Appearance** tab and sync to the App Group. `displayFraction`/`displayText` on `LimitWindow` flip the ring/bar fill + number for "used"; the widget reloads its timeline on a progression change.
- **Activity heatmap** — the popover's last-7-days **cost card is a button**: it flips the popover body (`PopoverView.showHeatmap`) to a GitHub-style punchcard (`ActivityHeatmapGrid` in `PlayfulComponents.swift`) with a Back button, backed by `AppState.activityHeatmap`/`loadActivityHeatmap`. **Footer** shows `snapshot.source.cliVersion` (statusline-only; nil on OAuth/claude.ai tiers) as a link to the Claude Code changelog; the old "Add account" button was dropped (it duplicated the gear → Settings).

### Data-source fallback order

Tier 1 is used while the statusline bridge is fresh; when stale, tiers 2–3 run (rate-limited). Each tier falls through to the next on failure.

| Priority | Pipeline                 | Source                                                                               |
| -------- | ------------------------ | ------------------------------------------------------------------------------------ |
| 1        | `StatuslinePipeline`     | `StatuslineBridge` → `~/.claude-meter/sessions/<accountKey>/<session_id>.json` (per-account) |
| 2        | `OAuthPipeline`          | `GET https://api.anthropic.com/api/oauth/usage` · `Authorization: Bearer <token>`    |
| 3        | `ClaudeAIPipeline`       | `GET https://claude.ai/api/organizations/{orgId}/usage` · `Cookie: sessionKey=<key>` |
| —        | `CachedSnapshotPipeline` | Terminal fallback: last persisted snapshot, marked stale                             |

`AppState.makePipeline` builds bottom-up, skipping disabled sources:
`StatuslinePipeline → OAuthPipeline → ClaudeAIPipeline (needs Keychain creds) → CachedSnapshotPipeline`.

Poll cadence and the statusline staleness / API-fallback cooldown are all **hardcoded 60 s** (not user settings). Settings & persisted keys: see `SPECS.md` §2.7 and §8.

`scheduleRebuildPipeline()` debounces source-toggle rebuilds (300 ms) and does not restart an active poll loop.

**Energy-aware poll loop** — `AppState.startPolling()` is gated by `PowerMonitor` (app target; AppKit `NSWorkspace` sleep/wake + IOKit battery — never in Core). Parking uses `screensDidSleep` only (not `willSleep`, so a cancelled sleep doesn't stall polling). While `isDisplayAsleep` the loop skips polling and re-checks every 300 s (`asleepRecheckSeconds`); `PowerMonitor.onWake` triggers an immediate `refreshNow()` so the number isn't stale a full interval after wake. On battery the 60 s base is ×2 (`batteryPollMultiplier`). `PowerMonitor` is `@MainActor`; its `NSWorkspace` observer tokens live in a plain `ObserverBag` so cleanup runs from a nonisolated `deinit` (a `@MainActor` class can't touch isolated non-`Sendable` state from its own deinit under Swift 6). Test `AppState.init(pipeline:)` skips `PowerMonitor`.

### Networking — `ProviderHTTP.swift`

- **All** provider HTTP goes through `ProviderHTTPClient.shared` (a `HTTPTransport`): one cookie-less ephemeral session (10 s) behind `RedirectGuardDelegate`, which drops any redirect that isn't same-origin HTTPS — credentials (`Bearer`/`Cookie`) must never be replayed off-origin or downgraded. OAuth, claude.ai, and status clients all use it.
- `HTTPRetryPolicy` (`.none` / `.transient`) gives bounded retries (idempotent methods only, honors `Retry-After`, exp backoff capped at 8 s). `.transient` excludes 429 (OAuth handles its own backoff) and also retries selected `URLError` timeouts. claude.ai + status GETs use `.transient`; OAuth keeps its own cross-poll 429 `blockedUntil` gate and uses `.none`.
- **Inject a stub `HTTPTransport`** to unit-test a client without network (see `AnthropicStatusClient(transport:)` and `TransportInjectionTests`).

### Keychain reads

- `OAuthKeychain.loadResult()` / `loadManualResult()` return `KeychainReadResult { found / missing / temporarilyUnavailable / invalid }`; `mapKeychainStatus` classifies the `OSStatus` (a locked Keychain → `temporarilyUnavailable`, `errSecAuthFailed` → `invalid`, never `missing` on error). `OAuthPipeline.poll` and `fetchEnrichment` branch on these (prefer in-memory cache on `.temporarilyUnavailable`). `load()`/`loadManual()` remain the `Optional` convenience wrappers.

---

## Statusline bridge

`StatuslineBridge.install(configDirs:)` runs on launch and each poll while statusline is enabled (idempotent + self-healing). It prepends a bash snippet to **each discovered config dir's** `settings.json` `statusLine.command` (via `AppState.installStatuslineBridgeIfNeeded` → `ConfigDirDiscovery.discover`, run off-main) that derives the **account key** from `$CLAUDE_CONFIG_DIR` (basename, one leading dot stripped, sanitized to `[alnum._-]`, fallback `claude`), extracts `session_id` (same sanitization), atomically writes stdin to `sessions/<accountKey>/<session_id>.json`, and sets `refreshInterval: 1`. The no-arg `install()`/`uninstall()` are `~/.claude`-only shims; a dir with invalid-JSON `settings.json` is skipped (its error surfaced after) without blocking the others.

- **Multi-account is the whole point** — power users run several Claude accounts via `CLAUDE_CONFIG_DIR=~/.claude-x claude`. Rate limits are **per account**, so the bridge tags each window's files by account and the app never blends them. `ConfigDirDiscovery` is the single source of truth for the account key/label and **must stay byte-identical to the bash snippet** (explicit ASCII allow-set, *not* Unicode `Character.isLetter`). The payload JSON carries no org/email, so the config dir is the only stable identity. OAuth/claude.ai stay **single-slot** — `OAuthPipeline` enrichment (Opus/extra/plan) decorates the active account only.
- **Per-account grouping + merge** — `readDataGrouped(maxAge:)` buckets fresh `*.json` by account subdir (legacy flat files + the legacy `statusline.json` → default `claude`) and runs `mergePayloads` **within each account only** — never across, since rate-limit buckets are independent: five-hour and weekly both use **max `resets_at`** (most recent observation). `StatuslinePipeline` mirrors the **active account** into the snapshot's top-level fields and lists the rest in `ClaudeUsageSnapshot.accounts` (nil only for a lone *default* `claude` account → `current.json` byte-identical to before; a lone *non-default* account is surfaced as a single-element list so the popover can key per-account name/plan overrides by account key). Menu bar / notifications / widget consume the active account; the popover's "Other accounts" section shows the rest. `readData(maxAge:)` is a back-compat shim returning the active account's merged payload.
- **Active-account selection** (`selectActive`/`activitySignature`) — the active account is the one **most recently used**, detected by diffing each account's *activity signature* (`total_cost_usd` / `total_api_duration_ms` / used % / code-lines — fields that only move on a real API call) across polls; the account whose signature changed most recently wins, idle accounts freeze their last-active time. **Don't use file mtime or `resets_at`**: the bridge rewrites every session file once a second (`refreshInterval: 1`) so idle-but-open looks fresh, and `resets_at` marks when a window *started*, not recent use (this caused an idle account with a later window to wrongly win). Exact ties (cold start / pipeline rebuild, where every account is freshly seeded) fall back to a **sticky** key (the previous active, seeded at init from the last snapshot's `accounts[].isActive` so a relaunch keeps the right account), then window-reset recency (`payloadRecency`), then key order. Switch granularity is one poll (≤60 s) on the menu bar; opening the popover calls `refreshNow` for an immediate re-select.
- **Discovery** — `ConfigDirDiscovery.discover` scans `~/.claude*` (dirs with `settings.json` or `projects/`, always including `~/.claude`) ∪ `AppGroupConfig.configuredConfigDirs`, minus `disabledAccountKeys` (the default `claude` is never disablable), deduped by resolved path + account key. Two **independent** off-main consumers run it each poll: `AppState.scanCostModels` (so the cost union is correct from the first poll, even with the statusline source off) and `installStatuslineBridgeIfNeeded` (gated on the statusline source; cancels its prior in-flight task to coalesce rapid toggles). Settings → Statusline Bridge card lists discovered accounts (toggle + add-custom-path, validated via `isPlausibleConfigDir`); changes call `scheduleRebuildPipeline()`.
- **Disabling filters the read path too** — `disabledAccountKeys` gates discovery (install + cost union) **and** `StatuslinePipeline.eligibleGroups` (the read path, injected at `makePipeline` construction, never dropping `claude`). Read-time filtering is required because discovery alone doesn't stop a disabled account: its already-installed bridge snippet keeps writing `sessions/<key>/` files, so without the filter it would still show in the popover and could win active-account selection.
- **Migration / self-repair** — `installOne()` strips _all_ leading bridge snippets (current + `legacyBridgeSnippets`, which now includes the pre-account per-session snippet) via `strippedOfAnyBridge` (loops to collapse chains) before prepending once. Until Claude Code re-runs the statusline, pre-existing flat `sessions/*.json` age out by the 60 s window (no active file move).
- **Snippet quoting** — `session_id` is pulled with `sed -n "s/.*\"session_id\":\"\([^\"]*\)\".*/\1/p"`; the account key with `A=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}");A=${A#.};…|tr -cd "[:alnum:]._-"`. Keeping `sed`/`tr` in double quotes avoids escaping single quotes inside the outer `bash -c '…'`. Verify byte-exactness via the install round-trip test (the raw `#"…"#` snippet survives JSON encode/decode). Empty/missing id → `default.json`; empty account → `claude`.
- **Pipe order** — bridge must be _prepended_ (`bridge | userCmd`) and must `printf "%s" "$I"` stdin through so the user's statusline still renders.
- **`rate_limits` may be absent** — only present for Claude.ai subscribers after the first API response; `StatuslinePipeline` requires `five_hour` or `seven_day` before accepting bridge data.
- **Parser version** `statusline-1.0`; diagnostics mode check is `hasPrefix("statusline")`.

## Staleness & rolling windows

- **File mtime ≠ data freshness** — an open-but-idle session re-emits its last (stale) snapshot every second, so the file stays fresh while the numbers are hours old. The real freshness signal is `resets_at`.
- **Expired windows read 0%** — Claude's windows are _rolling_, so once `resets_at` passes the window has reset. `LimitWindow.resolved(asOf:)` encodes it (past reset → `percentUsed: 0`, `resetsAt: nil`; next reset isn't predictable so no countdown). Applied in `StatuslinePipeline.displayWindow`, menu bar, `UsageCardView`, widget, and `NotificationPolicy`. Widget timeline refreshes at `min(nextReset, now+15m)`.
- **Usage pace** (`UsagePace.swift`) — `LimitWindow` has `percentUsed` + `resetsAt` but **not** the window span, so pace takes a `LimitWindowKind` (`.session` = 5 h, `.weekly` = 7 d). `percentTimeElapsed(kind:asOf:)` = `(span − timeUntilReset)/span`; returns `nil` when `resets_at` is implausible (past reset or > span away). `pace` classifies used vs. elapsed (±5 pt = on pace). Compute on the **`resolved(asOf:)`** window so a just-reset window reads `.unknown`, not stale. `UsageCardView(paceKind:)` drives the badge; session→`.session`, both weekly cards→`.weekly`. Menu-bar percent uses `LimitInfo.bindingDisplayPercent` (highest window, matches severity).
- **`lastPolledAt` advances only on successful polls**; derive staleness from `snapshot.lastSuccessfulPollAt` (`staleAfterSeconds`, default 180 s, in `AppGroupConfig`).
- **Claude vs Cursor staleness** — `isStale` ORs both for menu-bar UX; Claude notifications use `claudeIsStale` only.

## OAuth usage API (Claude Code token)

- **Keychain** — `OAuthKeychain` uses Security.framework (`SecItem*`); service `Claude Code-credentials`, account `NSUserName()`. Auto creds vs app-owned manual creds (service `com.jewei.claudemeter-oauth`, account `oauthManual`).
- **`oauthMode` gate** — `OAuthPipeline` only calls the API when `oauthMode` is `auto` or `manual` (`AppGroupConfig.oauthModeKey`); empty skips to tier 3. Manual disconnect deletes the app-owned entry and clears `oauthMode`.
- **Auto refresh is in-memory only** — refreshed auto tokens are cached in `OAuthPipeline` for the session; we do **not** write back to Claude Code's Keychain entry.
- **Decode `UsageResponse`, not `[String: QuotaEntry]`** — the endpoint returns extra keys (`limits`, `spend`, `extra_usage`, nulls). `utilization` is already 0–100; don't ×100. `QuotaEntry.utilization` is optional so null/empty windows degrade to "unknown" instead of failing the whole decode.
- **Windows mapped** — `five_hour` → session, `seven_day` → `currentWeekAllModels`, `seven_day_opus` → `currentWeekOpus` (often the binding limit for Max), `extra_usage` → `ExtraUsage` (monthly overage $). All feed severity + notifications (`weeklyOpus` scope). The statusline bridge and claude.ai client parse `seven_day_opus` too.
- **Statusline can't see Opus/extra/plan** — Claude Code's statusline `rate_limits` only emits `five_hour` + `seven_day`. `seven_day_opus`, `extra_usage`, and `subscriptionType` exist **only** in the OAuth response. `OAuthPipeline.fetchEnrichment` fetches them and `AppState.oauthEnrichment` layers them onto a non-OAuth snapshot (gated on `oauthMode` being set). `extra_usage` amounts are integer **minor units** (`used_credits`/`monthly_limit` ÷ `10^decimal_places`), not dollars; `is_enabled:false` can coexist with real `used_credits` (e.g. `out_of_credits`).
- **429 backoff** — `OAuthPipeline` honors `Retry-After` (delta-seconds or HTTP-date) via a process-wide `OAuthSharedState.blockedUntil` gate shared by `poll` and `fetchEnrichment`; while blocked both skip the API and serve the fallback (default 60 s). Token refresh preserves `subscriptionType`. Sends `User-Agent: claude-code/<ver>`.
- **`expiresAt` is integer milliseconds** in the Keychain JSON; parse via `NSNumber`/`Int`/`Double`. Refresh when within 60 s of expiry.
- **Token refresh** — `POST https://console.anthropic.com/v1/oauth/token`, `grant_type=refresh_token`, client id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`; usage calls send `anthropic-beta: oauth-2025-04-20`. Ephemeral `URLSession`, no cookies, 10 s timeout.

## claude.ai API

- **Manual Cookie needs an ephemeral session** — `URLSession.shared` drops/overrides the `Cookie` header; `ClaudeAIUsageClient` uses a private ephemeral session (`httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`).
- **Keychain** — `ClaudeAIKeychain`, service `com.jewei.claudemeter`, accounts `claudeai.sessionKey` and `claudeai.orgId`. Session key is a browser cookie; never log it.
- **Org auto-resolve** — Org ID is optional in Settings; blank → `ClaudeAIUsageClient.resolveOrgId(sessionKey:)` calls `GET /api/organizations` and `selectOrganization` prefers the org with the `chat` capability (not blindly index 0), falling back to the first. Manual UUID paste still works.
- **Browser cookie import** — `BrowserCookieImporter.importClaudeSessionKey()` reads the `sessionKey` cookie from Chromium browsers (Chrome/Brave/Edge/Arc/Chromium), Firefox, and Safari, then org auto-resolve fills the rest. Host matching is exact (`claude.ai` / `*.claude.ai` only). Chromium decrypt: **v10** = PBKDF2-SHA1(pw,"saltysalt",1003,16) + AES-128-CBC (IV = 16×0x20); **v20** = AES-256-GCM (`v20`‖nonce12‖ct‖tag16) with a PBKDF2 32-byte key — **best-effort/unverified for v20 app-bound; iterate from device output**. Plaintext carries a 32-byte domain-hash prefix, so `extractSessionKey` locates the `sk-ant-` token. Reads via `sqlite3` + `security`; first Keychain access prompts the user. Cookie DBs are read `-readonly`, falling back to a `file:…?immutable=1` URI when the browser holds a WAL lock (Firefox while running blocks `-readonly`; spaces in the path are %20-encoded). Verified on-device: Chrome/Brave (v10), Firefox, Safari all import; v20 still unconfirmed (no v20 cookie seen yet). Never log the value (it's a credential).
- **Failure handling** — transient errors fall back to `CachedSnapshotPipeline` and surface a `ParseWarning` (`field: "claude.ai API"`); auth failures (401/403) are fatal and do **not** fall back.

## Cursor usage (opt-in)

- **Separate from Claude pipeline** — `cursorSourceEnabled` defaults `false`; polled in parallel via `pollCursor`, not part of `makePipeline()`.
- **Token read-only** — `CursorTokenStore` reads `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (batched `sqlite3 -readonly`, 10 s timeout) with Keychain fallback (`cursor-access-token` / `cursor-refresh-token`). Never writes back.
- **API** — unofficial Connect-RPC on `api2.cursor.sh` (`GetCurrentPeriodUsage`); may break without notice. `totalPercentUsed` is authoritative over raw spend/limit.
- **Refresh** — in-memory only for the app session; rotated refresh tokens are cached in `CursorUsageProvider`. Open Cursor if refresh fails.
- **UX** — `cursorError` surfaces in popover/settings/diagnostics. The **menu bar is Claude-only** — Cursor has its own popover card but is never folded into the menu-bar dot/number/error (it would otherwise dominate the nearest-limit signal). Not in widget/notifications yet.

## Notifications

- **`NotificationEngine` is an actor**; only processes non-stale Claude snapshots; thresholds via `AppGroupConfig.currentThresholds(defaults:)`.
- **Per-account diffing** — `NotificationPolicy.triggers` diffs the top-level (active-account) window against **that same account's own previous entry** (matched by id in `previous.accounts`), so an active-account switch compares like-for-like instead of two unrelated accounts. A newly-seen active account (no prior entry — a switch out of single-account history) has no baseline, so its current state surfaces once (de-duped). Single-account snapshots (no `accounts`) fall back to the top-level previous (same account). `LimitWindow.percentLeft(asOf:)` lives in **Core** (not `PlayfulTheme`) so this stays UI-independent.
- **Dedup** is one per `(scope, level, resetsAt-epoch)`; critical suppresses warning. When `resetsAt` is nil, falls back to the start of the next local day. `markFired` only after `UNUserNotificationCenter.add` succeeds. No sound.
- **Recovered ("refueled")** — a `level: "recovered"` trigger fires when a window the user was previously over (by its **raw** previous severity, so a reset/refill counts) drops back to normal; delivered with the energy voice ("You're refueled! …back to 100%. 🎉"). `NotificationPolicy.evaluate` resolves the *current* window but reads the *raw* previous percent so a reset isn't masked. All copy is energy-left framed.

## Widget / App Group

- **Sandboxed** — never fall back to `applicationSupport()`; read `SnapshotStore.appGroup()` only and return `nil` gracefully.
- **Activity-ring look** — depleting rings (outer weekly, inner 5-hour) + energy rows; medium/large add an `opus` row when present; timeline refresh includes `currentWeekOpus.resetsAt`. Adaptive cream/dark `containerBackground`.
- **Fonts bundled into the widget too** — Fredoka/Nunito via the widget's own `ATSApplicationFontsPath`; widget-local `WFont` mirrors `PFont` (don't import app tokens).
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
- Two config dirs with the same basename share an account key/subdir (same class as the `default.json` collision; revisit with a path-hash suffix only if it bites).
- Multi-account is statusline-only: OAuth/claude.ai tiers and per-account notifications are single-slot (active account). Active-account switch lags up to one poll (≤60 s) on the menu bar (opening the popover refreshes immediately); detection is per-poll activity-signature change, so two accounts used within the same 60 s poll tie-break by window-reset recency.
- Cursor usage is not in the notification engine yet.
