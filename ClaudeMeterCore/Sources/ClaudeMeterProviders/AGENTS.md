# Provider development rules

Follow the root [AGENTS.md](../../../AGENTS.md). Provider behavior is defined in
[SPECS.md](../../../SPECS.md), sections 3 to 5 and 10.

## HTTP, files, and secrets

- Use `ProviderHTTPClient.shared` or an injected `HTTPTransport`. Production uses one
  cookie-less ephemeral session, a 10 s idle timeout, an 8 MiB response cap, and a 30 s
  whole-send deadline including retries. Keep the chunk receiver, early Content-Length
  rejection, streamed-overflow cancellation, and dedicated bounded `Timeout.TaskBudget`.
  Redirects must retain the same HTTPS origin; never forward credentials off-origin.
- `.transient` retries only idempotent requests and selected transient errors. It honors
  `Retry-After` and caps exponential backoff at 8 s. It excludes 429. OAuth uses `.none`
  and its own shared gate. Test clients with injected transports.
- All `SecItem*` calls go through `KeychainGateway` with no-UI policy. Tests fail closed
  unless `CLAUDE_METER_ALLOW_LIVE_KEYCHAIN_TESTS=1`. Keep the dyld loaded-framework check
  for XCTest/Testing; process names and bundle paths miss `swiftpm-testing-helper`.
- Settings preflight uses attributes-only `credentialAvailability()`. Only `.available`
  proves an existing credential. The first secret `loadResult()` follows the confirmed
  Connect action. Preserve `found`, `missing`, `temporarilyUnavailable`, and `invalid`:
  a locked Keychain is temporary; `errSecAuthFailed` is invalid, never missing.
  Prefer in-memory credentials during temporary unavailability.
- Legacy `Claude Code-credentials` lookup falls through to hashed services only on
  genuine absence. Discover attributes for `NSUserName()` and select the newest
  modification date through `newestHashedService(among:)`. Never use `dump-keychain`
  or a `security` subprocess to read secrets.
- Use `BoundedRegularFileReader` for auth, settings, identity, events, and advisory JSON.
  Keep `O_NONBLOCK`, regular-file checks with `fstat`, byte caps, and descriptor reads.
  User auth/settings/identity/cache paths may follow links. App-owned statusline and
  event paths reject links, including parent account directories. Open the managed root,
  then traverse with `openat`; final-component `O_NOFOLLOW` is insufficient. Cleanup
  unlinks only the unchanged entry through its inspected descriptor and may leave empty
  directories. `Data(contentsOf:)` can block forever on a FIFO despite cancellation.

## Transcript scans and caches

- `JournalReader` contains static timestamp/day helpers and the shared transcript walk.
  Scan every enabled config dir's canonical `projects/` root, deduplicated by resolved
  path. Include top-level JSONL and direct `subagents/*.jsonl`. Exclude
  `agent-acompact-*` and `agent-aside_question-*` replays and deeper workflow journals.
  Continue across unreadable roots and report partial results.
- Both scanners read only the last 4 MiB of files larger than 8 MiB. Caches require
  device/inode, mtime, size, and local time zone. Cache only descriptor reads whose
  stamp stays stable and matches discovery. Keep nonblocking opens and link rejection.
  This detects atomic replacement, not every in-place edit with restored metadata.
- Cost combines cumulative chunks by `message.id + requestId`, taking the maximum per
  token field. Complete pairs reconcile across files within one canonical account root;
  separate accounts stay additive. Missing IDs use per-file fallbacks and never merge
  across files. Reparse changed files; growth does not prove an append.
- The `usage.cache_creation` 5m/1h breakdown wins over the legacy creation total across
  chunks and files. Never add both. Legacy-only writes are 5m; 1h writes cost twice input
  through `resolvedCacheWrite1h`. `ModelPricing` uses reviewed family estimates, with
  Sonnet as the default. Cached models.dev overrides need a non-future timestamp and
  positive, bounded input/output/cache-read/cache-write/derived-1h rates.
- Cost disk format v6 retains request identity and cache-tier provenance; rebuild older
  formats. Keep record limits of 20,000 / 8 MiB per file and 100,000 / 32 MiB per root.
  The constant-time LRU holds at most 2,048 files and 32 MiB of accounted records.
  Limits set `isPartialEstimate`. Filter time windows at read time and call `flushIfDue`
  no more than once per 10 minutes. Default totals cover seven days.
- Preserve `CostUsageResult.sourcePaths` on partial results so the app can verify root
  scope before retaining old totals. Cost and catalog work must not delay quota
  publication. Providers never write snapshots.
- Activity counts each `message.id` once within a file. Its 30-day grid uses local hours
  and Monday index zero, `(Calendar.weekday + 5) % 7`. Cache unfiltered local-day buckets
  and apply `daysBack` at read time. `ActivityCache` is memory-only with 2,048 LRU entries.
  Load activity on demand, never through `makePipeline`.

## Statusline and account identity

- Reconcile `StatuslineBridge.install(configDirs:)` on launch and enabled polls. Remove
  snippets from disabled accounts. With the source off, remove all snippets and purge
  session data if any valid file changed, even if another account has invalid JSON.
  Keep purge separate from uninstall so tests never touch the live managed directory.
  Process all config dirs before surfacing invalid-JSON errors. No-argument shims use
  only `~/.claude`.
- Installation strips all current/legacy leading snippets before prepending once. Keep
  `bridge | userCmd` order and pass stdin through unchanged. Set `refreshInterval: 1`
  and atomically write `sessions/<accountKey>/<session_id>.json`. Legacy flat files age
  out; do not move active files.
- `ConfigDirDiscovery` account keys must match the bash snippet byte-for-byte. Use the
  config basename, strip one leading dot, and keep only ASCII alphanumeric plus `._-`.
  Do not use Unicode `Character.isLetter`. Empty account becomes `claude`; empty session
  becomes `default.json`. Keep snippet quoting and JSON round-trip tests.
- Discovery combines plausible `~/.claude*` dirs with configured paths, deduplicated by
  resolved path and account key. Always include default `claude`; it cannot be disabled.
  Discover off-main for both cost scans and reconciliation, including when statusline is
  off. Filter disabled keys during installation, cost scans, grouped reads, and around
  the whole fallback chain. Old files and running bridges can survive snippet removal.
- Merge fresh payloads only within the same account. Session and weekly windows use
  maximum `resets_at`. Legacy flat files map to default `claude`. Mirror the active
  account in top-level snapshot fields. Keep `accounts == nil` only for a lone default
  account; a lone non-default account needs an array for stable overrides.
- Select active accounts from changes in the sorted per-session `activityFingerprint`
  plus merged usage percent. Do not use file mtime, reset dates, or whichever session
  supplied merged cost/duration/line fields. Idle accounts retain their activity time.
  Break ties by prior active key, seeded from the persisted snapshot, then reset recency,
  then key order. Closing a session registers one activity change. Detection takes one
  poll and refreshes on popover open.
- Require `five_hour` or `seven_day` before accepting a payload; `rate_limits` may be
  absent. Keep parser version `statusline-1.0` and diagnostics `hasPrefix("statusline")`.
- Known identity limits: duplicate config basenames share an account key, and sessions
  without IDs share `default.json`. Do not change persisted identity without migration.

## Claude OAuth

- `oauthMode` must be `auto` or `manual` before usage calls. Auto credentials belong to
  Claude Code; manual credentials belong to service `com.jewei.claudemeter-oauth`,
  account `oauthManual`. Disconnect clears mode and deletes only the app-owned entry.
- Disconnect revokes refresh generations under the same lock as cache/mode/deletion.
  A late response must not commit tokens or gate state. Settings verification also
  checks its generation before enabling a source.
- Auto refresh is memory-only. Never write rotated tokens to Claude Code's Keychain.
  Keep source refresh-token lineage: a same-lineage rotation wins even with an earlier
  expiry; a new Keychain source wins regardless of expiry and invalidates the generation.
  Concurrent callers share one request and a bounded generation-keyed result handoff so
  late callers cannot reuse a consumed token. Current-generation failures clear their
  cache; old generations must not clear or replace a new login.
- Parse `expiresAt` as integer milliseconds and refresh within 60 s of expiry. Reject
  empty refreshed tokens, retain `subscriptionType`, and clamp `expires_in` to 5 minutes
  through 7 days. Keep the usage beta/User-Agent headers and token request constants in
  the existing client; use the shared transport limits.
- Decode `UsageResponse`, not a dictionary of quota entries. `utilization` is already
  0 to 100. Null/empty windows become unknown. Map `five_hour`, `seven_day`, and
  `seven_day_opus` to session/all-models/Opus windows. Other `seven_day_<scope>` windows
  are display-only and must not affect severity, menu bar, alerts, or widget.
- Fold `limits` entries of kind `weekly_scoped` into those same keys using the first
  lowercased word of the model display name. Flat fields win; generic entries fill gaps.
  Ignore mirrored `session`/`weekly_all` entries. Keep downstream decoding independent
  of the wire form.
- `OAuthEnrichment?` has two absence levels. Outer nil means unavailable; a successful
  non-nil observation is complete, so nil Opus/scoped/extra/plan fields clear old values.
  Never turn this into a fill-only update. Enrichment failure retains its previous time
  and stales only OAuth details. Clear cached windows after their reset to unknown.
- Statusline supplies session/weekly usage; OAuth supplies live Opus and extra usage,
  with plan hints from credentials/identity. `extra_usage` values are minor units divided
  by `10^decimal_places`. Disabled extra usage can still report spending.
- Preserve typed failures through fallback. `OAuthCredentialIssue` owns shared Settings
  and popover copy; actionable credential failures direct users to `claude login`.
  Distinguish rejected refresh tokens from temporary backoff. Rate limiting is
  informational, with `rateLimitedUntil()` and `ResetPhrase` for its countdown.
  Not-connected, disabled-source, and ordinary network failures do not become credential
  notices.
- All usage/enrichment/account calls share `OAuthSharedState.rateLimitGate`. Account
  changes and interactive refresh never bypass it. `HTTPRetryPolicy.retryAfterSeconds`
  is the sole parser: non-positive seconds and past dates return nil, selecting the
  default 60 s block. Cap valid blocks at 24 h and never shorten an active block.
- Persist only backoff observation time and deadline. Enable storage before startup
  provider work; loading must not extend it. Reject expired/invalid records and clock
  changes implying more than 24 h remaining. Tests use isolated stores and skip live
  persistence through the loaded-framework check.

## Multi-account OAuth

- `MultiAccountOAuth` runs only with explicitly connected `oauthMode == "auto"`, not
  manual mode or the source toggle alone. The no-UI policy cannot suppress legacy
  Keychain ACL dialogs. Read each config dir's `Claude Code-credentials-<hash>`, where
  hash is the first eight SHA-256 hex digits of its absolute path. Default config tries
  the legacy service first. A symlink alias can miss the path-derived service.
- `AccountIdentityReader` uses `<configDir>/.claude.json`, except default identity is
  `~/.claude.json`. Preserve organization header precedence over local org UUID and
  `duplicateOrgAccountKeys` detection. Different config dirs can represent one login.
- Fetch discovered accounts every 300 s off-main with a 30 s timeout. Statusline wins
  live session/weekly windows and active selection. OAuth supplies extra metadata and
  accounts without live sessions. Same-account OAuth fetched after a statusline reset
  may replace inferred zero.
- For active-account Opus/scoped/extra/plan, select the newest complete timestamped
  bundle across direct and per-account OAuth. Per-account wins equal timestamps. Replace
  both top-level and active-account fields, including nil. If a default snapshot with
  nil accounts gains only a secondary reading, materialize default as active; never
  let the secondary repair its limits.
- Successful accounts replace cache entries; failed enabled accounts retain last-good
  readings. Clear retained pre-reset windows to unknown before merge. A 429 stops the
  remaining accounts through the shared gate. Never refresh secondary tokens; expired
  credentials degrade to statusline-only until Claude Code updates them locally.

## Codex

- Use one explicit home per account, with ambient `CODEX_HOME` or `~/.codex` implicit.
  Store additional homes by canonical resolved path; never scan `~/.codex*`. Keep
  per-path display names and omit account email from cards and persisted readings.
- `CodexAppServerClientPool` keeps one initialized process per home between polls. Its
  restart rules are correctness, not caching: re-read the credential identity on every
  fetch and never cache it, because a resident process holds its sign-in in memory and
  would otherwise answer for the previous account. Restart also on a changed `codex`
  executable, on child exit, and after any failed use, including a cancelled one, since an
  unread response desynchronizes the next request. Keep `F_SETNOSIGPIPE` on the child's
  stdin: a pooled child can exit between polls, and a plain write would end the app. The
  app stops pooled processes through `CodexSubprocesses`; only this layer starts one.
- Give each home its own provider/App Server and OAuth read. Run batches of three under
  one 60 s provider deadline and isolated timeout-task budget. Failed accounts retain
  last-good readings with separate last-attempt error/time and last-success time.
- `CodexOAuthCredentialsStore.identity` provides member/workspace ownership and an
  in-memory source fingerprint. Never persist the fingerprint or treat JWT claims as
  authentication proof. Token rotation may retain ownership; member/workspace changes
  cannot. Unknown-owner readings cannot be cached durably or used for quota alerts.
- Scrub subprocess environments with `AuthEnv.scrubbed` so inherited API keys, base URLs,
  and provider selectors cannot redirect account reads. Bound whole output with
  `BoundedProcessOutputCapture` and protocol lines with `BoundedProcessLineBuffer` at
  1 MiB. Bound the App Server stream backlog; never parse truncated credentials or JSON.
- Install `terminationHandler` before launch. Perform TERM grace/exit waits on a
  dedicated queue, never the cooperative executor or `waitUntilExit()`. All shutdown
  callers, including canceled callers, await the same reaping completion. Claim timeout
  before shutdown so a response during the grace period cannot win.
- Prefer App Server, then direct OAuth. `allSourcesFailed` must preserve both failure
  descriptions for sanitization at the app boundary. Retain `account/read.account.type`
  in `authMode`; failed advisory reads may leave it nil. Direct OAuth uses `.chatGPT`.
- Positional primary/secondary windows win. Only when both are absent, bucket
  `rateLimitsByLimitId` by duration: at most 24 h or unknown is session-like; longer is
  weekly-like. Select the most-used window per bucket and use its limit ID as the label.
- Isolate malformed optional credit/reset/plan metadata from valid quota. Keep direct
  OAuth quota decoding strict. `rateLimitResetCredits.availableCount` is authoritative;
  missing/capped detail rows do not mean zero. Display returned rows as space allows.
  Never call `account/rateLimitResetCredit/consume`.
- Map `prolite` to `Pro 5X`, `pro` to `Pro 20X`, and `go`/`plus` to `Go`/`Plus`.

## Grok and Cursor

Both are opt-in, secondary-only providers. Poll separately from `makePipeline`. Show
errors in popover, Settings, and diagnostics. Honor progression mode while severity
always receives percent used. Neither owns main-meter displays or quota alerts.

- Grok reads `GROK_HOME` or `~/.grok/auth.json`. Prefer the `auth.x.ai::<client-id>` OIDC
  entry over legacy accounts.x.ai. Never write or refresh tokens; expired tokens require
  login and must not be sent. The billing endpoint's `creditUsagePercent` wins. Proto3
  omission with a present `currentPeriod` means zero. Preserve fractional timestamp
  handling in `GrokTimestamp.parse`. Monetary `{val}` values are cents.
- Cursor reads its state DB through batched `sqlite3 -readonly`, with a 10 s timeout,
  then Keychain fallback through `KeychainGateway`. Never write credentials back.
  Keep `totalPercentUsed` authoritative over spend/limit and retain optional Auto and
  API bucket percentages.
- Cursor detection cache keys include regular-file identity for DB/WAL/SHM at alias and
  resolved paths, including creation/removal. Read the first 96 SHM bytes because mmap
  updates may not change mtime/size. Short/unstable regular SHM disables caching but
  permits bounded SQLite recovery. Non-regular or inaccessible metadata blocks reads.
  Cache only if the complete identity stays unchanged. Never cache a result that used
  Keychain fallback, whose changes have no file identity.
- Cursor process timeout includes queued launch. Record cancellation first; skip launch
  after timeout and terminate a process that finishes launching late. Never terminate
  before `run()` succeeds. Drain stdout on a dedicated queue after launch, even on
  overflow, and discard stderr. Reject overflow results. Shared launch workers must not
  be blocked by pipe readers waiting for their writer.
- Cursor refresh is memory-only with a bounded source-token-identity/generation handoff.
  Late callers can reuse a completed rotation; a new or restored source cannot use an
  old result. Direct users to open Cursor if refresh fails.
