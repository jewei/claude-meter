# Claude Meter — Development Notes

Concise, non-obvious gotchas that apply across the whole repository. Full
behaviour/spec lives in `SPECS.md`.

Area-specific gotchas live in a `CLAUDE.md` beside the code and load only when
you work under that directory — do not move them back here:

- `ClaudeMeterCore/Sources/ClaudeMeterProviders/CLAUDE.md` — networking, Keychain
  reads, statusline bridge, OAuth usage API, Codex/Grok/Cursor.
- `ClaudeMeter/CLAUDE.md` — playful UI / energy design, notifications.
- `ClaudeMeterWidget/CLAUDE.md` — widget and App Group.

## Build & test

```bash
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO  # compile check
swift test --package-path ClaudeMeterCore                                    # core tests
./scripts/verify-local.sh                                                    # full local gate
```

The App Group entitlement needs a real provisioning profile to _run_;
`CODE_SIGNING_ALLOWED=NO` is enough to _compile_.

CI (`.github/workflows/ci.yml`, push + PR on `main`) runs **`verify-local.sh` itself**
rather than restating the steps — keep it that way so the two can't drift. Add a new
check to the script, not to the workflow.

---

## Architecture

- **Main app** — `@MainActor final class AppState`; `MenuBarExtra` `.window` style; `LSUIElement = YES` (no Dock icon).
- **Core** — `ClaudeMeterCore` owns normalized models, storage, and policy; no AppKit/SwiftUI or external I/O, Swift 6 strict concurrency.
- **Providers** — `ClaudeMeterProviders` owns statusline/OAuth, Keychain, HTTP, transcript scans, and Codex/Cursor/Grok adapters; depends only on Core. Provider tests live in `ClaudeMeterProvidersTests`.
- **Widget** — sandboxed `ClaudeMeterWidgetExtension`; opens only `SnapshotStore.appGroup()` and validates `main-meter.json` through Core's `MainMeterPublication` seam.
- **Shared container** — `group.com.jewei.claudemeter`; `AppGroupConfig` owns the suite name and syncs display settings.
- **Pipeline protocol** — `ClaudeMeterPipeline.poll(now:kind:) async throws -> ParseResult` (`RefreshKind` = `.background` / `.interactive`), with a `poll(now:)` convenience defaulting to `.background`; `AppState.pipeline` is `any ClaudeMeterPipeline`. **`kind` may only gate throttles that spare an external API on idle cycles — never correctness rules.** It must not be able to jump the OAuth 429 gate (that protects Anthropic, not our request budget), which is why `OAuthPipeline` merely forwards it.
- **Poll lifecycle** — each cycle captures one immutable `PollConfiguration`; optional providers publish a coherent `ReadingState` (`current`/`stale`/`failed`) so stale data, timestamps, and errors cannot drift apart.
- **Main meter** — `MainMeterReading` is Core's provider-neutral model for presentation policy and `main-meter.json`; Claude remains the migration default, Codex is explicit. The selected provider owns hero/first section/menu bar/header timestamp/widget/quota alerts. Missing selected data stays unavailable; provider fallback would change the percentage's meaning.
- **Advisory poll sidecars** — Anthropic service status is best-effort and runs as a coalesced unstructured task; never join it to the authoritative Claude usage fetch with `async let` or a task group. A slow advisory request must not delay publishing fresh quota data or inherit the required fetch's failure lifecycle.
- **Snapshot I/O is bounded** — `SnapshotStore` runs reads/writes on dedicated threads (2 s read / 10 s write) behind a per-store circuit breaker. App Group filesystem calls can wedge even on `open(2)`; after a timeout, fail that store fast so repeated polls cannot leak one blocked thread each. Independent stores intentionally have independent breakers.
- **`project.pbxproj` is hand-maintained** (no xcodegen). A new file needs a `PBXFileReference`, `PBXBuildFile`, group child entry, and build-phase entry, all with consistent 24-char hex UUIDs.
- **`JournalReader`** — **statics only**: timestamp/day-string helpers, `defaultProjectsPath`, and the `transcriptFiles` walk, used by `CostUsageScanner`/`ActivityScanner` (disk scans run off-main). The old instance side (per-day message counts + `JournalCache`) had no callers anywhere and was removed.
- **`CostUsageScanner`** — scans `assistant` lines for `message.usage` across **every discovered config dir's `projects/`** (`projectsPaths:`, deduped by resolved path — cost is additive across accounts; one unreadable root `continue`s instead of zeroing the union; the single-path `projectsPath:` init stays as a shim). Walks top-level `*.jsonl` **plus each session's `subagents/*.jsonl`** via `JournalReader.transcriptFiles` — subagent transcripts carry their own usage the parent never repeats (skipping them dropped ~⅓ of real spend); context-fork replays (`agent-acompact-*`/`agent-aside_question-*`) are excluded (they re-emit the parent's usage verbatim), and the walk is non-recursive below `subagents/` so `workflows/` journals are never touched. Dedups streaming chunks by `message.id + requestId` (or line index when ids are absent) taking the **max** per token field (counts are cumulative, summing over-counts), prices per family via `ModelPricing` (`opus`/`haiku`/`fable`/Sonnet-default substring match — estimates only), and fills `ClaudeUsageSnapshot.models` (last 7 days, one unioned total). **Cache writes are tier-split**: the `usage.cache_creation` breakdown (`ephemeral_5m/1h_input_tokens`) wins when present (never sum it with the legacy `cache_creation_input_tokens` total — that double-counts); no breakdown → legacy total is 5m. The 1h tier bills 2× input (`Rate.resolvedCacheWrite1h`; models.dev only publishes the 5m rate, so catalog entries derive it) — Claude Code now writes 1h caches for top-level sessions. Files >8 MB are tail-read (4 MB); `CostUsageResult.isPartialEstimate` surfaces incomplete totals. Per-file cache (`CostUsageCache`) keyed by mtime+size with LRU cap (2048); disk format v2 (v1 caches discarded — a merged cache-write total can't be tier-split); window filtering at read time; the disk flush is rate-limited to once per 10 min (`flushIfDue`) because any active session dirties the cache every poll.
- **`ActivityScanner`** — sibling scanner for the popover activity heatmap: a `7×24` grid (`counts[weekday][hour]`, **weekday 0 = Monday … 6 = Sunday** via `(Calendar.weekday + 5) % 7`; hour in **local** time) of assistant-message counts over the last 30 days. Dedups streaming chunks by `message.id` **within each file** (counts each message once). Shares the same root-walk + tail-read behavior as `CostUsageScanner` (including the `subagents/` walk + context-fork skip via `JournalReader.transcriptFiles`), with an **in-memory per-file cache** (`ActivityCache`, keyed mtime+size; buckets stored **unfiltered** with their local day string so any `daysBack` window is filtered at read time; deliberately not persisted, but LRU-capped at 2048 like `CostUsageCache`). It runs **on demand** (`AppState.loadActivityHeatmap`, off-main) when the user taps the cost card, not every poll — first open per app session pays the parse (~12 s cold here), later opens are stat walks (~50 ms). Not wired into `makePipeline`.

### Data-source fallback order

Tier 1 is used while the statusline bridge is fresh; when stale, the OAuth tier runs (rate-limited). Each tier falls through to the next on failure.

| Priority | Pipeline                 | Source                                                                               |
| -------- | ------------------------ | ------------------------------------------------------------------------------------ |
| 1        | `StatuslinePipeline`     | `StatuslineBridge` → `~/.claude-meter/sessions/<accountKey>/<session_id>.json` (per-account) |
| 2        | `OAuthPipeline`          | `GET https://api.anthropic.com/api/oauth/usage` · `Authorization: Bearer <token>`    |
| —        | `CachedSnapshotPipeline` | Terminal fallback: last persisted snapshot, marked stale                             |

`AppState.makePipeline` builds bottom-up, skipping disabled sources:
`StatuslinePipeline → OAuthPipeline → CachedSnapshotPipeline`.

Poll cadence and statusline staleness are **hardcoded 60 s** (not user settings). The **API-fallback cooldown is 120 s** (`StatuslinePipeline.fallbackCooldown`): at 60 s it equalled the poll cadence, so with no live Claude Code session *every* poll hit `/api/oauth/usage` (~60 calls/hour against an undocumented endpoint that throttles with hour-long `Retry-After`s). It must stay **below `AppGroupConfig.defaultStaleAfterSeconds` (180 s)** — the cached snapshot served during cooldown keeps its original `lastSuccessfulPollAt`, so a longer cooldown parks the UI in "Data may be stale"; both invariants are asserted in `StatuslineFallbackCooldownTests`. Opening the popover now bypasses it (`refreshNow(kind: .interactive)` → `PollConfiguration.refreshKind`), so the popover always shows live data; the bypass still *marks* the window so one open can't become two API calls. **The cooldown still can't go much higher**: the 180 s staleness ceiling is what binds, and the bypass doesn't move it — the menu bar reads `lastSuccessfulPollAt` continuously, with no open-popover moment to refresh on. Going further means making staleness tier-aware (an OAuth snapshot within its own refresh interval isn't stale), which is a separate design change. Pipeline behavior and persisted display keys: see `SPECS.md` §§3.1 and 7.

`scheduleRebuildPipeline()` debounces source-toggle rebuilds (300 ms) and does not restart an active poll loop.

**Energy-aware poll loop** — `AppState.startPolling()` is gated by `PowerMonitor` (app target; AppKit `NSWorkspace` sleep/wake + IOKit battery — never in Core). Parking uses `screensDidSleep` only (not `willSleep`, so a cancelled sleep doesn't stall polling). While `isDisplayAsleep` the loop skips polling and re-checks every 300 s (`asleepRecheckSeconds`); `PowerMonitor.onWake` triggers an immediate `refreshNow()` so the number isn't stale a full interval after wake. On battery the 60 s base is ×2 (`batteryPollMultiplier`). `PowerMonitor` is `@MainActor`; its `NSWorkspace` observer tokens live in a plain `ObserverBag` so cleanup runs from a nonisolated `deinit` (a `@MainActor` class can't touch isolated non-`Sendable` state from its own deinit under Swift 6). Test `AppState.init(pipeline:)` skips `PowerMonitor`.

`NetworkMonitor` (app target; `Network`/`NWPathMonitor` — never in Core) is the connectivity analogue: it fires `onReconnect → refreshNow()` on a lost→regained transition (`wasSatisfied` guard, hops from the monitor's background queue to `@MainActor`), so a Wi-Fi drop / network switch / VPN flap refreshes immediately instead of waiting out the interval. Like `PowerMonitor`, it's skipped by `AppState.init(pipeline:)`.

`MemoryPressureMonitor` (app target; `DispatchSourceMemoryPressure`) listens for warning/critical pressure on a utility queue, hops to `@MainActor`, trims the shared `CostUsageCache` and `ActivityCache`, then calls `malloc_zone_pressure_relief` off-main. Both trims are correctness-neutral: activity is rebuilt on demand; cost drops unflushed performance-only progress but preserves its last disk checkpoint and deliberately does **not** reload all persisted entries in the same process (later scans repopulate only touched files). It is skipped by `AppState.init(pipeline:)`, like the other system monitors.

---

## Staleness & rolling windows

- **Reset wording is standardized** — every "resets/refills …" surface (popover cards, ring/bar cards, hero, notifications, widget, Cursor/Codex/Grok subtitles) goes through Core's `ResetPhrase`: minutes under 1 h, hours under 48 h (minute detail kept below 12 h), whole days at 48 h+ ("in 4 days"). Never a calendar date or weekday. Widget uses `compact` ("4d"); prose uses `spoken` ("in 4 days"). Don't reintroduce per-surface `DateFormatter`s.
- **File mtime ≠ data freshness** — an open-but-idle session re-emits its last (stale) snapshot every second, so the file stays fresh while the numbers are hours old. The real freshness signal is `resets_at`.
- **Expired windows read 0%; expired stale observations are unknown** — Claude's windows are _rolling_, so a current observation whose `resets_at` passes resolves to `percentUsed: 0`, `resetsAt: nil` via `LimitWindow.resolved(asOf:)`; the next reset isn't predictable. A cached fallback observed before that reset cannot describe usage accumulated afterward, so `CachedSnapshotPipeline` clears expired windows before publishing the stale snapshot. This keeps menu bar, account cards, widget, and policy from presenting false capacity. Widget timelines refresh at `min(nextReset, now+15m)`.
- **Usage pace** (`UsagePace.swift`) — `LimitWindow` has `percentUsed` + `resetsAt` but **not** the window span, so pace takes a `LimitWindowKind` (`.session` = 5 h, `.weekly` = 7 d). `percentTimeElapsed(kind:asOf:)` = `(span − timeUntilReset)/span`; returns `nil` when `resets_at` is implausible (past reset or > span away). `pace` classifies used vs. elapsed (±5 pt = on pace); `paceInsight` supplies compact copy and an expected display fraction. Compute on the **`resolved(asOf:)`** window so a just-reset window reads `.unknown`, not stale. Bar cards show a neutral expected-position tick that mirrors for left/used progression plus pace text; ring cards show text only for their primary session/weekly rows. Pace is display-only and must never tint the tick or feed severity. `PredictiveNotificationTracker` uses session and weekly pace to forecast depletion. Menu-bar percent uses `LimitInfo.bindingDisplayPercent` (highest window, matches severity).
- **`lastPolledAt` advances only on successful polls**; derive staleness from `snapshot.lastSuccessfulPollAt` (`staleAfterSeconds`, default 180 s, in `AppGroupConfig`).
- **Selected-meter staleness** — menu bar, hero, widget, and quota alerts read `mainMeterIsStale`; provider-card notices retain their own lifecycle. A failed Codex refresh does not age a recent last-good observation, but it also is not a new notification observation.

## Swift 6 concurrency

- `DateFormatter` / `ISO8601DateFormatter` / `NumberFormatter` aren't `Sendable` — create per call, or cache as a read-only `nonisolated(unsafe) static let` (both formatter classes are documented thread-safe on macOS **when never mutated after creation** — see `JournalReader`'s cached formatters; hot paths must not allocate per line).
- Heavy poll work (`pipeline.poll`, `CursorUsageProvider.fetchUsage`, `JournalReader`) runs in `Task.detached`; only published state updates on `@MainActor`.
- `queue.sync` inside `queue.async` on the same serial queue deadlocks — async wrappers call queue-local helpers directly.
- `Task.detached` from `@MainActor` (e.g. `installStatuslineBridgeIfNeeded`) must capture only `Sendable` state.

## Diagnostics sanitizer

Always sanitize before logging or copying. `DiagnosticsSanitizer.sanitize` redacts emails, home paths (`/Users/<name>`), UUIDs, `sk-ant-*` / `oidc-*` tokens, JWTs (`eyJ…`), `Bearer …`, `sessionKey=…`, labeled token fields (`access[_]token`, `refresh[_]token`), and labeled CLI fields (`Session name:`, `Organization:`, `Cwd:`, `Email:`, `Session id:`).

---

## Known gaps

- No explicit `fsync` on snapshot atomic writes.
- `default.json` collides if multiple sessions ever lack a `session_id` (rare — Claude Code always sends one).
- Two config dirs with the same basename share an account key/subdir (same class as the `default.json` collision; revisit with a path-hash suffix only if it bites).
- Secondary-account Claude tokens are **not** refreshed (expired → that account degrades to statusline-only until its next local use). A config dir reached through a symlink can miss its hashed Keychain entry (hash is over the path Claude Code saw) → account stays statusline-only. Active-account detection lags up to one poll (≤60 s); two accounts used within the same poll tie-break by window-reset recency.
- Closing a Claude Code window changes an account's `activityFingerprint` (one fewer session), so it registers as activity once. Far cheaper than the old per-poll churn, and self-corrects on the next poll.
