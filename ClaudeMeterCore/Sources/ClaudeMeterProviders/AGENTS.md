# Provider development rules

Follow the root [AGENTS.md](../../../AGENTS.md). Provider behavior is defined in
[SPECS.md](../../../SPECS.md), sections 3, 4, and 8.

## Domain adapters

- `ClaudeSnapshotAdapter` and the Codex/Cursor/Grok adapter extensions convert current
  output to Core's `ProviderSnapshot`. Do not expose credentials or wire metadata there.
- Preserve config account keys and canonical Codex home IDs. Cursor/Grok use a single
  `default` connection slot because their usage output has no opaque member ID.
- Construct `UsageWindow` at this boundary. Preserve nil percentages and reported reset
  times. Keep balances in declared units, with reset-credit totals separate from details.
- All four providers implement Core's `UsageProvider` through adapters. Keep
  authentication and wire decoding in the existing clients. Convert errors to sanitized
  `UsageProviderFailure`; pass cancellation through. Cursor missing/rejected credentials
  set `retainsLastGood` false. Grok retains its existing last-good failure policy.

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
- Use `BoundedRegularFileReader` for auth, settings, identity, and advisory JSON.
  Keep `O_NONBLOCK`, regular-file checks with `fstat`, byte caps, and descriptor reads.
  User auth/settings/identity/cache paths may follow links. Legacy captured-data
  paths reject links, including parent account directories. Open the managed root,
  then traverse with `openat`; final-component `O_NOFOLLOW` is insufficient. Cleanup
  unlinks only the unchanged entry through its inspected descriptor and may leave empty
  directories. `Data(contentsOf:)` can block forever on a FIFO despite cancellation.

## Claude OAuth

- `ClaudeProviderAdapter` captures current configuration in validation. UsageStore supplies
  the only previous normalized reading. Keep only timing, identity metadata, diagnostics
  and refresh-ID-scoped pending data in the adapter, never a second usage cache.
- Restore legacy snapshots and filter disabled accounts before fetch. Keep old snapshots
  stale. Primary OAuth has a 60 s deadline; discovery has 5 s. The existing secondary
  batch has 30 s. Claude owns these bounds; do not add a redundant store timeout.
- `didAccept` commits metadata and enqueues the legacy archive once. `ClaudeReadingStore`
  creates, reads and writes SnapshotStore on its serial queue. Accepted writes remain
  ordered and survive cancellation; `waitForPersistence` awaits them without blocking UI.
  No top-level Claude account mirror may enter app state. It exists only in the old disk format.

- `oauthMode` must be `auto` or `manual` before usage calls. Auto credentials belong to
  Claude Code; manual credentials belong to service `com.jewei.claudemeter-oauth`,
  account `oauthManual`. Disconnect clears mode and deletes only the app-owned entry.
- Disconnect revokes refresh generations under the same lock as cache/mode/deletion.
  A late response must not commit tokens or gate state. Settings verification also
  checks its generation before enabling a source.
- Auto mode never refreshes Claude Code credentials. Use access tokens until expiry,
  then report login-required and retain stale usage. Re-read the source each poll.
  Manual mode alone rotates and persists app-owned credentials. Concurrent manual
  callers share one request and a bounded generation-keyed result handoff. A replaced
  source invalidates the generation; late work cannot replace a newer login.
- Parse `expiresAt` as integer milliseconds. Manual mode refreshes within 60 s of
  expiry. Reject empty refreshed tokens, retain `subscriptionType`, and clamp
  `expires_in` to 5 minutes through 7 days. Keep the usage beta/User-Agent headers
  and token request constants in the existing client; use the shared transport limits.
- Decode `UsageResponse`, not a dictionary of quota entries. `utilization` is already
  0 to 100. Null/empty windows become unknown. Map `five_hour`, `seven_day`, and
  `seven_day_opus` to session/all-models/Opus windows. Other `seven_day_<scope>` windows
  are display-only and must not affect severity or the menu bar.
- Fold `limits` entries of kind `weekly_scoped` into those same keys using the first
  lowercased word of the model display name. Flat fields win; generic entries fill gaps.
  Ignore mirrored `session`/`weekly_all` entries. Keep downstream decoding independent
  of the wire form.
- OAuth responses replace complete account observations. Missing optional fields clear
  old values. `extra_usage` is a live provider balance; divide minor units by
  `10^decimal_places`. Disabled extra usage can still report spending.
- Keep typed failures in provider diagnostics. `OAuthCredentialIssue` owns shared Settings
  and popover copy; actionable credential failures direct users to `claude login`.
  Distinguish rejected refresh tokens from temporary backoff. Rate limiting is
  informational, with `rateLimitedUntil()` and `ResetPhrase` for its countdown.
  Not-connected, disabled-source, and ordinary network failures do not become credential
  notices.
- All usage/account calls share `OAuthSharedState.rateLimitGate`. Account
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
  duplicate-organization detection. Different config dirs can represent one login.
- Preserve config-directory account keys and configured-path discovery. Resolve duplicate
  paths and keys deterministically. The default `claude` account cannot be disabled.
- The primary OAuth request runs at the existing poll cadence. Secondary accounts run
  every 300 s, off-main, with a 30 s batch deadline. Exclude the primary attempted account
  from that batch. Secondary credentials remain read-only; expired tokens need login.
- Successful accounts replace complete observations. Failed enabled accounts retain their
  last-good time and become stale. Clear expired retained windows to unknown. A 429 stops
  remaining requests. Account selection uses an exact pin or the nearest quota limit.

## Upgrade migrations

- Legacy attention and statusline cleanup run once per launch until complete. Match only
  shipped literals, inspect all formerly managed config paths, preserve user settings,
  and use bounded reads plus atomic writes. Keep `refreshInterval` because no old value
  was saved. Never create captured-data directories or install commands.
- Captured-file cleanup uses anchored descriptors and unchanged-entry checks. Failed
  statusline cleanup leaves its versioned completion flag unset for the next launch.

## Codex

- `CodexProviderAdapter` captures current homes for each refresh. Resolve
  home symlinks and read archives off-main; recheck refresh ownership after waiting. It
  receives previous normalized accounts from UsageStore. Never add a second usage cache.
  Retain ownership stamps and source diagnostics, plus only the newest refresh's staged
  preflight/save data. Match stages by refresh ID; obsolete work must not replace them.
- `CodexReadingStore` retains the v2 archive under `codexLastGoodReadings.v1`. Restore
  only after owner validation. `didAccept` updates ownership/diagnostics and enqueues
  the archive once, after UsageStore checks refresh ownership. Read, encode and write
  archives on the provider-local serial queue. Retain only the newest pending archive
  until the async persistence wait completes, so a new refresh can validate accepted
  data without waiting for disk. Accepted writes survive cancellation and run in
  acceptance order. Never save an unaccepted fetch or return a save closure. No account
  email or source fingerprint may enter the archive.
- Return valid previous accounts from `validatePrevious`; UsageStore publishes them
  before it calls `fetch`, so an invalid owner disappears
  promptly. Unavailable configured accounts have nil `observedAt`, empty quota rows and
  sanitized `lastError`. Failed retained accounts keep their successful observation time.
- Use one explicit home per account, with ambient `CODEX_HOME` or `~/.codex` implicit.
  Store additional homes by canonical resolved path; never scan `~/.codex*`. Keep
  per-path display names and omit account email from cards and persisted readings.
- Prefer direct OAuth from the configured home's bounded auth file. Claude Meter reads
  credentials but never consumes a Codex refresh token or writes `auth.json`/Codex Keychain.
  Codex owns token rotation and persistence. Ignore the removed source-mode preference.
- Only `CodexOAuthCredentialsError.notFound`, `missingTokens`, `decodeFailed`, `unreadable`,
  `expiredAccessToken` and `CodexUsageError.loginRequired` permit App Server recovery.
  Quota-request 401/403 map to `loginRequired`. Network errors, deadlines, 429/5xx and invalid
  usage do not start recovery. API-key auth has no subscription quota and clears old usage.
- Treat a bounded, numeric JWT `exp` within 60 s as a recovery hint. Unknown expiry uses
  direct HTTP. Claims never authenticate an account. Do not retain refresh-token fields.
- Recovery launches one temporary `codex app-server`, initializes it, asks `account/read`
  with `refreshToken: true`, reads rate limits and awaits shutdown on success or any error.
  This lets Codex use its own credential backend. No child is retained between refreshes.
  Keep `F_SETNOSIGPIPE` so a dead child's stdin cannot terminate the app.
- Give each home its own provider/App Server and OAuth read. Run batches of three under
  one 60 s provider deadline and isolated timeout-task budget. Failed accounts retain
  last-good readings with separate last-attempt error/time and last-success time.
- `CodexOAuthCredentialsStore.identity` provides member/workspace ownership and an
  in-memory source fingerprint. Never persist the fingerprint or treat JWT claims as
  authentication proof. Token rotation may retain ownership; member/workspace changes
  cannot. Unknown-owner readings cannot be cached durably.
- Scrub subprocess environments with `AuthEnv.scrubbed` so inherited API keys, base URLs,
  and provider selectors cannot redirect account reads. Bound protocol lines with
  `BoundedProcessLineBuffer` at
  1 MiB. Bound the App Server stream backlog; never parse truncated credentials or JSON.
- Install `terminationHandler` before launch. Perform TERM grace/exit waits on a
  dedicated queue, never the cooperative executor or `waitUntilExit()`. All shutdown
  callers, including canceled callers, await the same reaping completion. Claim timeout
  before shutdown so a response during the grace period cannot win.
- Keep source/auth-mode metadata in provider diagnostics and the existing Codex archive,
  never ProviderSnapshot. Combined recovery failures preserve both sanitized reasons.
  Normal direct reads include reset-credit totals when supplied. A positive count permits
  one optional GET for reset-credit details with the same loaded token and account ID.
  Use a four-second whole-request deadline, an isolated timeout-task budget, and no retries.
  Attach only available, unexpired rows when the detail total matches the quota total.
  Missing or invalid expiry stays unknown. Detail failure preserves quota and the count,
  clears old details, and never triggers auth recovery, including on 401/403. Pass cancellation
  through. Recovery can also supply details; never launch a process just to obtain them.
- Positional primary/secondary windows win. Only when both are absent, bucket
  `rateLimitsByLimitId` by duration: at most 24 h or unknown is session-like; longer is
  weekly-like. Select the most-used window per bucket and use its limit ID as the label.
- Isolate malformed optional credit/reset/plan metadata from valid quota. Keep direct
  OAuth quota decoding strict. `rateLimitResetCredits.availableCount` is authoritative;
  missing/capped detail rows do not mean zero. Display returned rows as space allows.
  Never call `account/rateLimitResetCredit/consume`.
- Map `prolite` to `Pro 5X`, `pro` to `Pro 20X`, and `go`/`plus` to `Go`/`Plus`.

## Grok and Cursor

Both are opt-in, secondary-only providers. Fetch through UsageStore. Show
errors in popover, Settings, and diagnostics. Honor progression mode while severity
always receives percent used. Neither owns main-meter displays.

- Grok reads `GROK_HOME` or `~/.grok/auth.json`. Prefer the `auth.x.ai::<client-id>` OIDC
  entry over legacy accounts.x.ai. Never write or refresh tokens; expired tokens require
  login and must not be sent. The billing endpoint's `creditUsagePercent` wins. Proto3
  omission with a present `currentPeriod` means zero. Preserve fractional timestamp
  handling in `GrokTimestamp.parse`. Monetary `{val}` values are cents.
- Cursor credentials come from `state.vscdb` through system SQLite. Open with
  `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` and `readonly_shm=1`; never use immutable
  mode for the live DB. Bind the four ItemTable keys in one SELECT, then finalize/close.
  Never write Cursor data or create/repair sidecars. Missing required WAL/SHM state
  fails cleanly and permits read-only Keychain fallback through `KeychainGateway`.
- Run credential reads off-main. Keep the existing provider timeout, SQLite row-size
  limit and cancellation checks. Busy/locked/read errors are temporary and retain
  last-good usage if Keychain cannot supply credentials. Never show raw SQLite paths.
  Reject non-regular DB/sidecar paths. No subprocess, detection cache, file identity
  cache or manual SHM/WAL contents read is needed. SQLite handles committed WAL data.
- Decode UTF-8, ASCII UTF-16LE blobs and BOM-marked UTF-16 values. Keep whitespace/quote
  handling and selective access/refresh Keychain fallback. Never cache Keychain detection.
  Keep `totalPercentUsed` authoritative and retain Auto/API percentages.
- Cursor never consumes refresh tokens or writes credentials. Read the access token
  per request. Reject known expired tokens; allow unknown expiry to reach the API.
  Direct users to open Cursor after expiry or rejection. Preserve transient errors.
