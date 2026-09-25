# Provider development rules

Provider behavior is defined in [SPECS.md](../../../SPECS.md) sections 3, 4, and 7.
These rules cover implementation constraints.

## Adapters

- All four providers implement Core's `UsageProvider` through adapters that convert
  client output to `ProviderSnapshot`. Authentication and wire decoding stay in the
  existing clients. Credentials and wire metadata never enter the snapshot.
- Keep config account keys and canonical Codex home IDs. Cursor and Grok use one
  `default` slot because their usage output has no opaque member ID.
- Construct `UsageWindow` here. Keep nil percentages and reported reset times. Keep
  balances in declared units, with reset-credit totals separate from details.
- Convert errors to sanitized `UsageProviderFailure` and pass cancellation through. Missing
  or rejected Cursor credentials, and missing or expired Grok credentials, set
  `retainsLastGood` false.
- Cursor and Grok retain readings only for the accepted credential stamp. Keep the stamp
  in memory, outside normalized models. Validate it before fetch and after each response;
  a source change drops previous usage, even on a temporary failure.
- Adapters keep timing, identity metadata, diagnostics, and refresh-ID-scoped pending data
  only. UsageStore supplies the only previous reading; add no second usage cache.

## HTTP, files, and secrets

- Use `ProviderHTTPClient.shared` or an injected `HTTPTransport`, and test clients with
  injected transports. Keep the chunk receiver, early `Content-Length` rejection,
  streamed-overflow cancellation, and dedicated `Timeout.TaskBudget`. Redirects keep
  the same HTTPS origin; credentials never go to another origin.
- `.transient` retries only idempotent requests and selected transient errors, never 429.
  It honors `Retry-After` and caps backoff at 8 s. OAuth uses `.none` and its own gate.
- All `SecItem*` calls go through `KeychainGateway` with no-UI policy. Tests fail closed
  unless `CLAUDE_METER_ALLOW_LIVE_KEYCHAIN_TESTS=1`. Keep the dyld loaded-framework check
  for XCTest/Testing: process names and bundle paths miss `swiftpm-testing-helper`.
- Settings preflight uses attributes-only `credentialAvailability()`; only `.available`
  proves a credential. The first secret `loadResult()` follows the confirmed Connect
  action. Keep `found`, `missing`, `temporarilyUnavailable`, and `invalid` distinct: a
  locked Keychain is temporary, and `errSecAuthFailed` is invalid, not missing. Prefer
  in-memory credentials while the Keychain is temporarily unavailable.
- Legacy `Claude Code-credentials` lookup falls through to hashed services only on genuine
  absence. Discover attributes for `NSUserName()` and pick the newest modification date
  with `newestHashedService(among:)`. Read secrets only through Security.framework, never
  `dump-keychain` or a `security` subprocess.
- Read auth, settings, identity, and advisory JSON with `BoundedRegularFileReader`: keep
  `O_NONBLOCK`, `fstat` regular-file checks, byte caps, and descriptor reads.
  `Data(contentsOf:)` can block forever on a FIFO, even after cancellation.
- User auth, settings, identity, and cache paths may follow links. Legacy captured-data
  paths reject links, including parent account directories: open the managed root and
  traverse with `openat`, because a final-component `O_NOFOLLOW` is not sufficient.
  Cleanup unlinks only the unchanged entry through its inspected descriptor.

## Claude OAuth

- `ClaudeProviderAdapter` captures configuration during validation, restores legacy
  snapshots, and removes disabled accounts before fetch. Old snapshots stay stale.
- Claude owns its 5 s discovery, 60 s primary, and 30 s secondary-batch deadlines; add
  no store timeout.
- `didAccept` commits metadata and enqueues the legacy archive once. `ClaudeReadingStore`
  creates, reads, and writes `SnapshotStore` on its serial queue. The top-level account
  mirror exists only in the disk format, never in app state.
- Usage calls require `oauthMode` `auto` or `manual`. Manual credentials use service
  `com.jewei.claudemeter-oauth`, account `oauthManual`. Disconnect clears the mode and
  deletes only that app-owned entry.
- Disconnect revokes the refresh generation under the same lock as cache, mode, and
  deletion, so a late response cannot commit tokens or gate state. Settings verification
  checks its generation before it enables a source.
- Auto mode uses Claude Code's access token until expiry, then reports login-required
  and keeps stale usage. It re-reads the source each poll and never refreshes it.
- Manual mode alone rotates and persists tokens. Concurrent callers share one request
  and a bounded, generation-keyed result handoff. A replaced source invalidates the
  generation, so late work cannot replace a newer login.
- Parse `expiresAt` as integer milliseconds. Manual mode refreshes within 60 s of expiry,
  rejects empty refreshed tokens, keeps `subscriptionType`, and clamps `expires_in` to
  5 minutes through 7 days. Keep the usage beta and User-Agent headers and token constants
  in the existing client.
- Decode `UsageResponse`, not a dictionary. `utilization` is already 0 to 100; null or
  empty windows are unknown. `five_hour`, `seven_day`, and `seven_day_opus` map to
  session, all-models, and Opus. Other `seven_day_<scope>` windows are display-only and
  never affect severity or the menu bar.
- Fold `limits` entries of kind `weekly_scoped` into those keys by the first lowercased
  word of the model display name. Flat fields win; generic entries fill gaps. Ignore the
  mirrored `session` and `weekly_all` entries.
- A response replaces the complete account observation; missing optional fields clear
  old values. `extra_usage` minor units divide by `10^decimal_places`. Disabled extra
  usage can still report spending.
- `OAuthCredentialIssue` owns Settings and popover copy; actionable credential failures
  direct users to `claude login`. Keep rejected refresh tokens distinct from temporary
  backoff. Rate limiting is informational and counts down with `rateLimitedUntil()` and
  `ResetPhrase`. Not-connected, disabled-source, and network failures are not credential
  notices.

### Rate-limit gate

- All usage and account calls share `OAuthSharedState.rateLimitGate`; account changes and
  interactive refresh go through it too.
- `HTTPRetryPolicy.retryAfterSeconds` is the only parser. Non-positive seconds and past
  dates return nil, which selects the default 60 s block. Cap valid blocks at 24 h and
  never shorten an active block.
- Persist only the observation time and deadline. Enable storage before startup provider
  work; loading never extends a block. Reject expired or invalid records, and clock
  changes that imply more than 24 h remaining.

### Multiple accounts

- `MultiAccountOAuth` runs only when `oauthMode == "auto"` was explicitly connected.
  No-UI policy cannot suppress legacy Keychain ACL dialogs.
- Each config dir reads `Claude Code-credentials-<hash>`, where hash is the first eight
  SHA-256 hex digits of its absolute path. The default config tries the legacy service
  first. A symlink alias can miss the path-derived service.
- `AccountIdentityReader` uses `<configDir>/.claude.json`; the default identity is
  `~/.claude.json`. The organization header wins over the local org UUID. Keep
  duplicate-organization detection: different config dirs can hold one login.
- Resolve duplicate paths and keys deterministically. The default `claude` account cannot
  be disabled.
- Secondary accounts run every 300 s, off-main, in one batch that excludes the primary
  account. Their credentials are read-only; expired tokens need login. A 429 stops the
  remaining requests.

## Upgrade migrations

- Legacy attention and statusline cleanup run once per launch until complete. Match only
  shipped literals, check every formerly managed config path, keep user settings, and use
  bounded reads and atomic writes. Keep `refreshInterval`: no old value was saved.
- Migrations only remove. They create no captured-data directories and install no commands.
- Failed cleanup leaves its versioned completion flag unset for the next launch.

## Codex

### Lifecycle and archive

- `CodexProviderAdapter` captures current homes for each refresh, resolves home symlinks
  and reads archives off-main, and rechecks refresh ownership after each wait. It keeps
  ownership stamps, source diagnostics, and only the newest refresh's staged data,
  matched by refresh ID.
- `validatePrevious` returns valid previous accounts; UsageStore publishes them before
  `fetch`, so an invalid owner disappears promptly.
- `CodexReadingStore` keeps the v2 archive under `codexLastGoodReadings.v1` and restores it
  only after owner validation. `didAccept` updates ownership and diagnostics and enqueues
  the archive once. Read, encode, and write on the provider-local serial queue. Keep only
  the newest pending archive until its write completes, so a new refresh can validate it
  without waiting for disk. Save only accepted fetches, in acceptance order.
- Account email and source fingerprints never enter the archive or cards.
- Unavailable configured accounts have nil `observedAt`, empty quota rows, and a sanitized
  `lastError`. Failed retained accounts keep their successful observation time.

### Homes and credentials

- Each account has one explicit home; ambient `CODEX_HOME` or `~/.codex` is implicit.
  Store additional homes by canonical resolved path; do not scan `~/.codex*`.
- Read credentials from the configured home's bounded auth file. Codex owns token
  rotation: never use its refresh token or write `auth.json` or the Codex Keychain.
- `CodexOAuthCredentialsStore.identity` supplies member/workspace ownership and an
  in-memory source fingerprint. Token rotation can keep ownership; a member or workspace
  change cannot. Unknown-owner readings are never cached on disk.
- A bounded numeric JWT `exp` within 60 s is a recovery hint; unknown expiry uses direct
  HTTP. Claims never authenticate an account. Retain no refresh-token fields.

### App Server recovery

- Only `CodexOAuthCredentialsError.notFound`, `missingTokens`, `decodeFailed`,
  `unreadable`, `expiredAccessToken`, and `CodexUsageError.loginRequired` start recovery.
  Quota 401/403 map to `loginRequired`. API-key auth has no subscription quota and clears
  old usage.
- Recovery launches one temporary `codex app-server`, initializes it, calls `account/read`
  with `refreshToken: true`, reads rate limits, and awaits shutdown on every path. Retain
  no child between refreshes.
- Scrub the child environment with `AuthEnv.scrubbed` so inherited API keys, base URLs,
  and provider selectors cannot redirect account reads. Keep `F_SETNOSIGPIPE`.
- Bound protocol lines with `BoundedProcessLineBuffer` at 1 MiB and bound the stream
  backlog. Never parse truncated credentials or JSON.
- Install `terminationHandler` before launch. Run TERM grace and exit waits on a dedicated
  queue, never the cooperative executor or `waitUntilExit()`. All shutdown callers,
  including canceled ones, await the same reaping. Claim the timeout before shutdown so a
  late response cannot win.
- Combined recovery failures keep both sanitized reasons. Source and auth-mode metadata
  stay in diagnostics and the archive, never in `ProviderSnapshot`.

### Fetches and decoding

- Each home has its own provider and OAuth read. Run at most three at once, and start
  the next home when a slot frees. All homes share one 60 s provider deadline with an
  isolated timeout-task budget.
- A positive reset-credit count permits one detail GET with the same token and account ID:
  a 4 s deadline, an isolated timeout-task budget, and no retries. Attach only available,
  unexpired rows, and only when the detail total matches the quota total. Detail failure
  keeps quota and count, clears old details, and never starts recovery, even on 401/403.
  Never start a process only to get details.
- `rateLimitResetCredits.availableCount` is authoritative; missing detail rows do not mean
  zero. Never call `account/rateLimitResetCredit/consume`.
- Positional primary/secondary windows win. Only when both are absent, bucket
  `rateLimitsByLimitId` by duration: 24 h or less, or unknown, is session-like; longer is
  weekly-like. Pick the most-used window per bucket; its limit ID is the label.
- Isolate malformed optional credit, reset, or plan metadata from valid quota. Direct
  OAuth quota decoding stays strict.

## Grok and Cursor

Both are opt-in secondary providers that fetch through UsageStore and never own the main
meter. Neither writes nor refreshes credentials.

- Grok reads `GROK_HOME` or `~/.grok/auth.json` and prefers the `auth.x.ai::<client-id>`
  OIDC entry over legacy accounts.x.ai. Never send an expired token. The billing
  endpoint's `creditUsagePercent` wins. Proto3 omission with a present `currentPeriod`
  means zero. Keep fractional timestamps in `GrokTimestamp.parse`. Money `{val}` is cents.
- Cursor opens `state.vscdb` through system SQLite with
  `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` and `readonly_shm=1`, never immutable mode on
  the live DB. Bind the four ItemTable keys in one SELECT, then finalize and close.
  Never write Cursor data or create or repair sidecars; missing WAL/SHM state fails
  cleanly and permits the read-only Keychain fallback.
- Cursor reads run off-main with the provider timeout, SQLite row limit, and cancellation
  checks. Reject non-regular DB and sidecar paths. Busy, locked, and read errors are
  temporary. Never show raw SQLite paths. SQLite handles committed WAL data; read no
  SHM/WAL contents manually.
- Decode UTF-8, ASCII UTF-16LE blobs, and BOM-marked UTF-16. Keep whitespace and quote
  handling and the selective access/refresh Keychain fallback. Cache no detection result.
  `totalPercentUsed` is authoritative; keep the Auto and API percentages.
- Cursor reads the access token per request. Reject known expired tokens; unknown expiry
  reaches the API. After expiry or rejection, direct users to open Cursor.
