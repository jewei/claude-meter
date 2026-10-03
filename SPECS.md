# Claude Meter specification

This document defines current user-visible behavior and stable system boundaries. The
[development rules](AGENTS.md) and directory-level `AGENTS.md` files define
implementation constraints. The [design reference](DESIGN.md) defines visual tokens and
components. Removed features are outside this specification.

## 1. Product contract

Claude Meter is a macOS 14+ menu-bar app that shows coding quota as energy left. It has
no Dock icon (`LSUIElement = YES`) and uses a SwiftUI `MenuBarExtra` with `.window`
style. Claude remains the default main meter for existing users. Users can select Claude
or Codex. Cursor and Grok remain secondary popover sources.

The app uses local credentials and reads provider quota under these rules:

- Provider credentials are read-only except for manually entered Claude OAuth tokens,
  which Claude Meter owns in Keychain.
- Provider secrets are never rendered, logged, or copied into diagnostics.
- Quota polling reads provider data. Independent token history reads retained local
  Claude Code, Codex, and Grok Build records and Cursor's account export. Token history
  has no prices or historical cost estimates. Provider-reported live balances remain
  visible.
- Only the explicitly selected main provider affects the hero, first popover section,
  menu-bar indicator, or header timestamp. Missing selected data never falls back to
  another provider.

## 2. Targets and ownership

| Target | Responsibility |
| --- | --- |
| `ClaudeMeter` | AppKit and SwiftUI presentation, settings, refresh scheduling, display sleep and wake, Sparkle |
| `ClaudeMeterCore` | Normalized snapshot models, storage, thresholds, reset formatting. No UI or provider I/O |
| `ClaudeMeterProviders` | OAuth, Keychain, HTTP, and all four provider adapters |

The app depends on Core and Providers. Providers depends on Core. Provider-specific wire
formats do not enter Core.

`AppState` creates and connects app services on MainActor. It coordinates presentation
and settings. `RefreshScheduler` uses an explicit `RefreshConfiguration` to control
global timing and decide which requests can start. `UsageStore` owns all provider usage
lifecycle and publishes Core `ReadingState<ProviderSnapshot>`. AppState owns no mutable
provider readings. `MainMeterReading` holds the selected provider quota data for
presentation and is not persisted.

### Shared provider domain

`ProviderSnapshot` is the shared model for all four providers. It holds a `ProviderID`,
an account array, and the latest included quota observation time. It has no selected or
active account. Each `ProviderAccountSnapshot` keeps its own optional observation time,
explicit stale flag, sanitized last error and last attempt time. A nil observation means
that the configured account has no usable data. Age-based staleness remains a consumer
policy.

Each account has a label, optional plan and public subtitle, ordinary `UsageWindow`
rows, and `BalanceItem` rows. Window percentages always mean used, from 0 through 100.
Adapters clamp finite values and keep unknown or non-finite values unknown. An
over-limit flag preserves severity after clamping. Window kinds support session and
weekly menu-bar choices. `contributesToQuota` excludes display-only scoped windows and
budget rows from selection. Only provider-reported reset times or end times enter
`resetAt`.

`UsageWindow.resolved` uses the existing `LimitWindow` reset rule. A current expired
window becomes zero with no next reset date. A stale expired window becomes unknown.
Resolution does not replace the stored authoritative timestamp. Presentation converts
used percentage to energy left. Account selection takes an exact pin, or the greatest
resolved quota usage. Ties retain input order. Unknown usage ranks below known zero.

| Provider output | Domain mapping | Account identity |
| --- | --- | --- |
| Claude snapshot and account array | Session, weekly, Opus, and other scoped windows. Plan and email subtitle, hidden on cards. Extra-usage amount, limit, currency, and paused state. Usage-limit reset grants | Existing config account key, including the existing unmapped OAuth key. Never email |
| Codex reading per home | Session and weekly windows classified by duration. Plan, credits, and reset allowances | Existing canonical home path used by account pins |
| Cursor usage | Authoritative billing percentage, optional Auto and API rows, billing end, plan, period spend, and period limit | `default`, a provider-local connection slot |
| Grok usage | Credit percentage, reported period end, on-demand spend, cap, and prepaid balance | `default`, a provider-local connection slot |

Cursor and Grok output no opaque member ID or reliable plan for Grok. Their slot keys do
not prove login ownership. Providers keep an internal, in-memory SHA-256 credential
stamp for each accepted reading. Validation clears previous readings when the source
credential changes. A read-only check after each request rejects a response or stale
retention from a changed source. The stamp never enters ProviderSnapshot, diagnostics,
or disk storage. Without a stable member ID, token renewal also invalidates the old
reading until the new credential succeeds. Metadata-only changes do not change the
stamp. Codex checks member and workspace ownership before it restores or publishes
last-good data. The home key alone is not sufficient. No token or credential fingerprint
enters the domain. Codex email stays omitted. Popover cards do not show the Claude
email.

Balance amounts use `Decimal` in the stated unit. They need not be money. Optional
limits retain live spend and budget pairs. `displayText` retains non-numeric states such
as unlimited credits and paused extra usage. Counted allowances have an authoritative
total plus optional title and expiry details. Detail count never replaces the total.
Codex reset-credit expiry is separate from a quota reset. It does not advance quota
freshness.

The provider module has one adapter per provider. Authentication, raw source and parser
metadata, and raw errors stay outside `ProviderSnapshot`. Sanitized account error text
belongs to the account. `ReadingState` lives in Core with current, stale, and failed
cases. A failed reading can include a snapshot of unavailable account labels and errors.
It has no successful poll time and no account observations. This preserves error cards
without inventing quota or maintaining another account array.

`AppState.normalizedSnapshots` reads UsageStore and applies account display overrides.
It performs no I/O and stores no second copy. All provider cards consume normalized
accounts, windows and balances. Existing Claude and Codex disk formats remain internal
to their provider boundaries.

### Token history

Each provider account card has a **Tokens used** section with **Today**, **Yesterday**,
and **Last 7 Days** rows. The section follows **Usage limit resets** for Claude and
Codex, and the existing quota details for Cursor and Grok. It appears only in expanded
cards; ring cards remain always expanded. This replaces the separate token card below
the account list. Last 7 Days includes today and the previous six local calendar dates.
Event timestamps assign records to dates. A timezone change requires a new projection.
Missing history is unknown, not zero. A successful empty Cursor export can establish
zero for its requested range.

This is a limited change to the 3.0 decision to remove transcript scans. Only token
counts return. There are no model prices, historical cost estimates, captured commands,
or changes to provider credentials. Token totals do not measure energy left and do not
affect account selection, quota freshness, the hero, or the menu bar.

Claude Code, Codex, and Grok Build history is labeled **This Mac**. These records can
include earlier logins and API-key sessions. Config dirs and local activity do not
establish historical account ownership. Each account card for the same local provider
shows the same provider total, without assigning it to that account. The source tooltip
states this scope. Other devices, deleted records, and web activity are outside this
scope. Cursor history is labeled **Account usage**.

- Claude reads assistant usage from `projects/**/*.jsonl` in enabled config dirs. A
  response contributes input, output, cache-read, and cache-write tokens. Streaming
  updates replace the prior response record. Request and message IDs remove copies.
- Codex reads `sessions` and `archived_sessions` under configured homes. It reconciles
  cumulative counters and duplicate session copies. Inherited fork history requires an
  owned boundary. Unresolved forks are skipped and make coverage partial. Cached input
  and reasoning output remain subsets of input and output.
- Grok reads completed-turn `usage.modelUsage` records in `sessions/**/updates.jsonl`.
  Event timestamps, rather than file modification dates, set the day. Event ID and
  model remove duplicate records. Total tokens are input plus output, including their
  cache and reasoning subsets. Unfinished turns are absent.
- Cursor requests the seven-day CSV export from
  `cursor.com/api/dashboard/export-usage-events-csv` with `strategy=tokens`. The existing
  access token supplies an in-memory dashboard cookie. No browser login or credential
  write is added. Its four token columns are disjoint. Prices and model names do not
  control whether valid tokens are counted. Credential changes invalidate account
  history; a post-request check rejects results from an old login.

Core owns `TokenUsageSnapshot` and the three calendar periods. Providers owns source
parsing and I/O. `UsageStore.tokenReadings` is the only owner of accepted history, with
its own `ReadingState`, loading state, and refresh ID. History runs independently of
quota on the existing global refresh opportunities. A history failure cannot fail a
quota reading or advance its successful poll time. Pause, sleep, disable, and newer
refreshes cancel history and reject late results. Disable also clears its reading.

All token history and parse caches are memory-only. A serial utility queue per local
source owns cached file offsets and parsed counters; prompts and responses are not
retained. Unchanged files need no body read. Growing journals use saved offsets after
checking file identity, the beginning, and the append boundary. Replacement,
truncation, same-size rewrites, and changed boundary bytes rebuild that file. This
assumes ordinary journal growth is append-only. A restart rebuilds the complete cache.

Scans prefer recently modified files and skip files last modified before the requested
range. Normal limits are 64 MiB of log input per scan, 8 MiB per file per scan, 1 MiB per
line, 2,048 files, 20,000 directory entries, 20,000 records per file, and 100,000 cached
records per provider. Incomplete final lines are read again. Oversized or malformed
records, unresolved counters, and reached limits make history partial. Reading resumes
on a later refresh when the byte limit was reached. No limit produces a complete zero.
History fetches have a 20 s deadline and at most two outstanding timed tasks per source.
Cursor uses the shared HTTP response bounds. The UI states partial or stale coverage.

### Provider lifecycle store

Core's `UsageProvider` has explicit validation, fetch and acceptance stages:

1. `validatePrevious(_:now:refreshID:)` returns reconciled previous accounts.
2. `fetch(now:previous:refreshID:)` returns a `ProviderSnapshot`.
3. `didAccept(_:refreshID:)` updates in-memory metadata and enqueues ordered
   persistence.
4. `waitForPersistence()` asynchronously waits for already accepted writes.

UsageStore supplies the same refresh ID to validation, fetch and acceptance. It checks
the active token, enabled state, and cancellation before reconciliation, after
reconciliation, before fetch, and after fetch. It publishes a changed reconciled value
before fetch. An unchanged value keeps its existing outer reading error and freshness. A
nil reconciled value clears it. The store checks the token, accepts through `didAccept`,
then publishes the final value without suspension. This orders ownership stamps and
diagnostics before observation. Disk success is not a condition for publication.
MainActor acceptance performs no blocking I/O, including Foundation file operations,
Keychain calls, or subprocess waits. It only updates memory and submits work to a
provider-owned queue.

After publication, the store clears loading and awaits `waitForPersistence`. This async
wait performs no blocking I/O on MainActor. A newer refresh sees the accepted snapshot
immediately. Cancellation, supersession or disable before acceptance prevents a save.
After acceptance, these events do not revoke the queued write. A thrown fetch failure
cannot overwrite last-good data. No later state publication occurs after the write wait.
Providers never call back into publication and return no side-effect closures.

Cursor and Grok validate credential ownership and accept an in-memory owner stamp. Their
persistence waits do nothing. Claude and Codex each keep at most one pending preflight
record and one pending save record, identified by refresh ID. These records carry
existing archive data, source diagnostics and account checks across stages. Fetch or
acceptance consumes these records. The next reconciliation replaces any remaining
record. These records never supply an independent last-good usage cache. Old stages
cannot replace newer records. Repeated acceptance of the same result performs no second
save.

Codex resolves configured home paths off-main during validation. Archive reads are
async, and the adapter checks cancellation and refresh ownership again after each
suspended step. Codex submits each accepted archive to one serial queue before
publication. Encoding, UserDefaults reads and UserDefaults writes run there. An accepted
archive cannot write before an earlier accepted archive finishes. The reading store
retains only the newest pending archive until its write wait completes. A new refresh
can validate this archive during a slow write. It cannot restore an older disk value
over the accepted observation. This temporary write buffer preserves raw archive fields
without adding a second usage-state owner. Archive format, ownership validation, and
email and fingerprint exclusions are unchanged.

Refresh operations await their accepted writes, without blocking presentation or the
main thread. There is no detached persistence task or shutdown daemon. Process exit can
still interrupt an outstanding write. The app does not add a quit delay or a durability
guarantee beyond existing storage. The next launch can fetch usage again.

`UsageStore` is an `@MainActor` observable application type, built with an explicit
array of providers indexed by ID. It owns the only mutable provider reading dictionary,
the refreshing set, and active refresh tasks. Main-actor work coordinates publication.
Cursor and Grok fetches use the existing detached 60-second timeout. Codex owns its
60-second batch deadline and bounded workers. Claude owns its discovery, primary OAuth
and secondary account deadlines. Neither has a redundant outer timeout. All admitted
providers start before the store awaits their results. Failures remain independent.

RefreshScheduler sends the admitted provider set to one UsageStore refresh call. Store
observation forwards through `AppState` to the views. There is no copied store state or
event stream. The store has no disk persistence.

A success publishes a current reading with the snapshot's observation time. A transient
failure retains the complete previous snapshot and successful timestamp as stale.
Without a previous usable value, it publishes failed. Unknown percentages remain nil.
Source account freshness is unchanged by the store: an account is effectively stale if
either the outer reading or the account is stale. Current Claude and Codex provider
readings can have mixed account ages. Age-based display staleness still uses the
existing threshold.

Codex uses current configuration for each refresh. Each home succeeds, retains an
ownership-validated previous observation as stale, or becomes unavailable with an
account error. If any account has usable data, the provider reading is current. This
includes an all-stale but still valid account set. If none has usable data, the reading
is failed and retains only unavailable account details. Failure never advances an
account observation time. Exact pins cannot substitute a different account. Nearest
selection excludes unavailable accounts and resolves stale reset windows to unknown
after expiry.

Each provider refresh has one token. A newer request cancels the old task and replaces
its token. Only the current token can publish or clear loading. Caller cancellation
affects only that caller's requests. It does not record a failure or cancel a newer
task. Disable cancels the active task, removes the reading and blocks late publication,
including across re-enable. Pause and display sleep cancel store work through the same
API.

Provider adapters sanitize errors and classify last-good retention. Cursor missing,
unauthorized or forbidden credentials clear its value while retaining the last
successful timestamp. Temporary errors preserve last-good data only while its credential
owner remains valid. Missing or expired Grok credentials clear previous usage. A
temporary credential read failure can retain the accepted reading when no source change
has been observed. Cancellation passes through without becoming a provider failure.

Cursor and Grok cards read normalized windows and balances. Cursor shows its total and
Auto and API percentages, plan, billing reset, and spend text. Its limit stays in the
balance but forms no displayed ratio, because bonus credit affects the percentage. Grok
shows its credit percentage, reset, and on-demand spend and cap text. Its prepaid
balance stays in the snapshot with no card row. Settings credential preflight is
separate from quota fetching.

### Global refresh scheduler

`@MainActor RefreshScheduler` owns one asynchronous timer, queued requests, and
`PowerMonitor`. AppState supplies only active state and enabled provider IDs. It
combines onboarding and pause state before supplying configuration. The scheduler
forwards enable and disable actions to `UsageStore`. It never reads `UserDefaults`. It
owns no provider values, credentials or storage.

The scheduler applies these refresh rules:

- Start and resume refresh enabled providers immediately once onboarding permits it.
- Every 300 s while awake, all enabled providers share one background refresh
  opportunity. Provider work already in progress is not duplicated. There is no
  distinction between main and secondary providers and no battery-dependent cadence.
- Popover open refreshes only missing, failed, provider-stale or at least 60 s old
  readings. Core's `ReadingState<ProviderSnapshot>.needsRefresh` uses the successful
  observation time. Invalid or future dates also request refresh. Account-level
  freshness remains provider-owned.
- Explicit manual refresh bypasses the age check and can supersede current work.
- Enabling a provider refreshes only that provider. Disabling cancels it and clears its
  reading. Credential, account, or source changes invalidate and refresh only the
  affected provider. These actions do not restart the timer or refresh unrelated
  providers.
- Display sleep cancels the timer, queued requests and active store work, with no
  periodic asleep checks. Wake refreshes missing, failed, stale or at least 300 s old
  readings, then starts a new 300 s timer. Recent data needs no extra fetch.
- Network changes do not trigger refresh. Normal cycles, popover open and manual refresh
  handle recovery. Authentication retries and backoff remain provider-owned.

Requests from the same actor turn merge into a provider set. UsageStore owns execution,
supersession and publication safety. The scheduler has no global cycle IDs or mutable
copy of provider readings. Pause and stop reject queued and late timer work.

Reset countdowns need no provider request. The popover updates its local time each
second while visible and cancels that timer when closed. UI age staleness uses 600 s by
default, with a minimum of 600 s for older settings and a maximum of 24 h. This leaves a
full normal refresh interval of headroom. Explicit provider or account failure can mark
data stale sooner. The 60 s interactive threshold is independent from this display
threshold.

## 3. Claude provider

Claude configuration flows through `ClaudeProviderAdapter`, OAuth usage and account
reconciliation, then into one normalized `ProviderSnapshot` in UsageStore. The adapter
uses the existing `OAuthPipeline` for the primary account and `MultiAccountOAuth` for
secondary accounts. These internal clients return data only. The app does not consume
`ParseResult`, `ClaudeUsageSnapshot`, or mirrored top-level account fields.

Validation reads a legacy last-good snapshot off-main when needed, removes disabled
accounts, and clears expired stale windows. A change between auto and manual mode
invalidates previous usage before fetching. UsageStore publishes validated state only
after its refresh-token check. Failed primary or secondary requests retain valid
previous accounts as stale with their original observation times. An account without
previous data remains visible with unknown windows and a sanitized error. A set with
fresh, stale, or unavailable accounts is current when at least one account has usable
data. An entirely unavailable set is failed. A successful account response replaces all
its fields.

The adapter owns a 5 s discovery bound, a 60 s primary bound and the existing 30 s
secondary batch bound. `ownsDeadline` prevents a redundant UsageStore timeout. Typed
source attempts, credential issues, account failures and duplicate-login metadata remain
read-only provider diagnostics. Only sanitized account failure copy enters the
normalized reading.

Fetch results control current, stale and failed presentation. There is no separate
service-status request. The global refresh policy is defined above. Claude account
timing and authentication backoff remain inside the provider.

### 3.1 OAuth

OAuth runs only when the mode is `auto` or `manual`:


- Auto mode reads Claude Code's legacy or hashed Keychain credential entries after the
  user explicitly confirms **Connect**. Settings preflight is attributes-only.
- Manual mode stores an app-owned Keychain item and reports save and delete failures.
- Automatic mode never consumes refresh tokens or writes Claude Code credentials. It
  uses access tokens until expiry. Expiry or rejection requires renewal in Claude Code.
  Previous usage stays stale. The next poll reads the renewed credential.
- Manual mode can rotate tokens, cache them, and save them to its app-owned Keychain
  item.
- Automatic credentials retain the exact Keychain service through reads and cache reuse.
  Each usage response belongs to its mapped config account. An unmapped login keeps a
  separate account key. Manual mode supplies the default account slot.
- Concurrent manual refreshes share one request. A bounded handoff retains the result
  for late callers that selected the same one-use token before it was rotated.
  Credential-generation keys prevent a replacement login from using an older result.
- Refresh failure clears the corresponding in-memory credential cache.
- Disconnect revokes the current credential generation before an in-flight refresh can
  restore cache or manual Keychain state. A disabled source cancels and rejects an
  in-flight connection result. Verification never turns the source back on.
- All usage and refresh requests use the shared cookie-less transport with same-origin
  HTTPS redirect enforcement.
- The process-wide 429 gate is shared by polling, verification, and per-account
  requests. It honors positive `Retry-After` delta or HTTP-date values up to a 24-hour
  safety maximum. This maximum prevents an invalid server value from disabling OAuth for
  the life of the app. App startup restores one provider-wide deadline from standard
  defaults. The record contains no credentials, survives restarts, and is never extended
  by loading it. Invalid or expired records and clock changes that imply more than 24
  hours remaining are rejected. Storage failure preserves the in-memory block. Test app
  initializers do not install persistence. Interactive refresh and account changes never
  bypass it.

The usage response maps `five_hour`, `seven_day`, `seven_day_opus`, dynamic scoped
weekly limits, `extra_usage`, and plan metadata. Flat scoped fields win over equivalent
entries in `limits[]`. Unknown or null windows do not fail the whole response. Extra
usage minor units are scaled by the response's decimal places.

The usage request adds the `cedar_ember=1` query flag, as claude.ai's usage page does.
Without the flag, the response omits the allowance. The usage response's
`cedar_ember.grants` list holds usage-limit reset grants. The server decides eligibility
by client surface from the User-Agent, so the usage request uses Claude Code's own
format, `claude-cli/<version> (external, cli)`. This changes the earlier decision to
keep `claude-code/<version>`. That value returns `eligible: false, ineligible_reason:
"surface"` with no grants. An unrecognized surface is unknown, so the card says "Not
reported". Any other ineligibility means the account is outside the program. The card
then says "0 available". Each grant has a label, `resets_left`, and optional `starts_at`
and `ends_at` times. The account keeps started, unexpired grants with resets left, as a
`usage-resets` balance: the total count plus one expiry detail row per reset. Counts are
bounded to 99 per grant. An invalid expiry date stays unknown. The decoder skips a
malformed grant. A malformed allowance leaves the quota windows intact. Resets are
display-only. The app never uses a reset.

A successful OAuth response replaces one complete account observation, including absent
optional fields. There is no second enrichment request. The primary credential is
excluded from the secondary request batch. Only manual credentials have a token refresh
path.

Multi-account OAuth runs only in auto mode. It reads each configured directory's
namespaced credential and local account identity. Secondary accounts retain the existing
five-minute request interval and read-only credential behavior. Expired secondary tokens
require a new Claude login. Each reading keeps its actual fetch time. Failed enabled
accounts retain stale last-good data. Expired retained windows become unknown. An exact
main-meter account pin wins. Otherwise, the app selects the account nearest its limit.
No session files, file activity, or Claude Code process activity influence selection.

Secondary request times are provider metadata, not a usage cache. Accounts not due keep
UsageStore's previous normalized observation and timestamp. The shared 429 gate and
token rotation remain independent of refresh acceptance. Interactive refresh cannot
bypass them.

### 3.2 Snapshot and staleness

`ClaudeReadingStore` owns legacy snapshot I/O. `SnapshotStore` atomically writes
Claude's `current.json` and sanitized `last-error.json` under `~/Library/Application
Support/ClaudeMeter/`. Writes follow account assembly and UsageStore acceptance.
Validation, store creation, upgrade import and writes run on one provider-local serial
queue. The queue preserves accepted write order. UsageStore publishes before awaiting
disk completion. A rejected result cannot write. Cancellation after acceptance does not
revoke a queued write. `SnapshotStore` reads accept regular files up to 4 MiB within 2
s. Writes have a 10 s limit. A timeout opens that store's circuit breaker. Restoration
uses the same bounds. Atomic writes have no explicit `fsync`. Startup onboarding can
check this archive asynchronously for existing-user evidence without taking ownership of
usage state.

On upgrade, a one-time import checks the former `~/Library/Group
Containers/group.com.jewei.claudemeter/Library/Application
Support/ClaudeMeter/current.json`. It imports only a newer usage observation, or fills
an empty local store. A successful check sets `didImportLegacyAppGroupSnapshot.v1` in
standard defaults. Read or write errors leave the key unset for a later launch. The
import does not delete legacy files or copy the old widget publication or error record.
Startup also requests this import through the same Claude storage queue when Claude is
disabled. A separate cleanup may remove the legacy source only after this completion key
is set.

`lastSuccessfulPollAt` changes only after a usable successful poll. Claude notices use
Claude staleness. An optional provider's stale state cannot make the Claude card stale.

Top-level fields mirror the first account only at the legacy persistence boundary. Each
account has its own quota, metadata, observation time, and stale flag. Old JSON session,
activity, and analytics fields are ignored. Old statusline snapshots are marked stale
when read. The first successful OAuth response replaces that account's observation.

Expired rolling windows resolve to 0% used and no reset date. Consumers call
`UsageWindow.resolved(asOf:isStale:)` before display or policy evaluation. Stale expired
windows become unknown instead of zero.

## 4. Optional providers

### 4.1 Cursor

Cursor is opt-in. Each credential read opens its known `state.vscdb` path through macOS
system SQLite, binds four ItemTable keys in one SELECT, then finalizes and closes. The
SDK module links libsqlite3. No external package or executable is required. Open flags
are `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`, with `readonly_shm=1`. SQLite handles
committed WAL data with normal locking. The reader never uses immutable mode. The reader
does not write the database or create or repair sidecars. A WAL database that needs
missing sidecars fails cleanly instead. See the [SQLite WAL read-only
rules](https://www.sqlite.org/wal.html) and [Unix VFS read-only SHM
behavior](https://github.com/sqlite/sqlite/blob/master/src/os_unix.c).

Regular-file checks reject devices and FIFOs at the database and existing sidecars. No
file identity cache or SHM-header inspection remains. Reads run off-main under the
existing provider timeout. Settings also uses a detached task. SQLite gets a 1 MiB row
limit, no busy wait, and a cancellation progress handler. Temporary busy, locked, or
read failures retain last-good usage if the existing Keychain fallback cannot supply
credentials. Missing credentials still require sign-in. Errors contain no raw SQLite
paths.

UTF-8, ASCII UTF-16LE blobs and BOM-marked UTF-16 values are decoded before the existing
whitespace and quote removal. Missing access or refresh values use the read-only, no-UI
Keychain gateway independently. No detection result is cached. Cursor never consumes
refresh tokens, caches rotated credentials, or writes credentials. It reads the current
access token for each request. Known expired tokens are not sent. Unknown expiry permits
a usage request. Expiry or HTTP 401 requires opening Cursor to renew the login.
Transport and server failures remain temporary errors. Cursor errors and staleness
appear only on its popover, Settings, and diagnostics.

### 4.2 Codex

Codex is opt-in and supports one implicit `CODEX_HOME` plus explicitly configured homes.
Each home has its own display name and quota observation. A rename changes labels only.
It starts no refresh. Normal refresh reads access credentials from that home's
`auth.json` and makes one direct HTTP usage request. When that response reports
available usage resets, it also requests their expiry details. It starts no Codex
process and has no source picker.

Malformed optional credit, reset, or plan metadata does not discard valid quota windows.
Unusable metadata stays unknown. A valid reset count remains available when optional
detail rows cannot be decoded. Direct OAuth quota decoding remains strict.

Claude Meter never consumes the Codex refresh token, rotates Codex credentials, or
writes Codex auth storage. Codex owns that state. Upstream Codex reloads credentials
before a managed refresh, exchanges the refresh token, and saves rotated tokens through
its selected backend. Supported backends include file, OS keyring, automatic selection,
and process-local memory. A new subprocess cannot recover another process's memory-only
login. See [OpenAI authentication documentation](https://learn.chatgpt.com/docs/auth)
and the [reviewed upstream
implementation](https://github.com/openai/codex/blob/30fc6864cc1318121eca1843c217fe00ce1212f1/codex-rs/login/src/auth/manager.rs).

Recovery is permitted only for these typed direct failures:

- `CodexOAuthCredentialsError.notFound`, `missingTokens`, `decodeFailed`, `unreadable`,
  or `expiredAccessToken`.
- `CodexUsageError.loginRequired`, produced by HTTP 401 or 403 from the quota request.

A numeric access-token JWT expiry within 60 seconds skips the direct request. Parsing is
bounded to 64 KiB and accepted date bounds. Malformed, absent or nonnumeric expiry means
unknown, so direct HTTP is attempted. Unverified claims are never authentication proof.
Network or DNS failures, timeouts, HTTP 429 or 5xx, decoding errors, and missing quota
do not launch recovery. They keep normal last-good stale behavior. API-key auth shows
unavailable subscription quota and cannot retain an earlier subscription observation. An
explicit `auth_mode: "chatgpt"` takes precedence over a stored `OPENAI_API_KEY`. That
mode requires OAuth tokens. Missing tokens permit credential recovery. Explicit API-key
mode still rejects subscription quota even when old OAuth tokens remain. Without an
explicit ChatGPT mode, a nonempty API key selects API-key auth. See [upstream mode
resolution](https://github.com/openai/codex/blob/7dae8c53d97e61cd774e4d6bcca5243c29ca615c/codex-rs/login/src/auth/manager.rs#L1763-L1780).

Recovery resolves Codex, launches one `codex app-server`, initializes, reads the account
with `refreshToken: true`, then reads rate limits. Codex handles any credential rotation
and backend writes. A successful result, error, timeout or cancellation awaits process
termination and reaping before the source returns. Startup and individual requests keep
5-second deadlines. Shutdown uses TERM, then SIGKILL after 0.25 seconds if needed, on a
separate queue. Environment scrubbing, bounded protocol output and SIGPIPE protection
remain. No process pool, idle eviction, executable cache or application shutdown hook
remains.

Source and auth-mode metadata remain in provider diagnostics and the compatible Codex
archive. `ProviderSnapshot` has no source implementation fields. When recovery also
fails, both failure reasons remain available for sanitized diagnostics. Account metadata
is optional, but a reported API-key mode stops the subscription quota request.

Last-good readings are persisted per resolved Codex home, without account email, and are
restored after ownership checks on the first refresh. `CodexProviderAdapter` owns
restore and save work. `UsageStore` accepts the save with final publication. A failed
refresh retains that reading and records the attempt error and time separately from the
last-success time. Observation staleness remains age-based. Healthy accounts continue
updating when another account fails. At most three accounts run at once. A free slot
starts the next account, so a stalled account does not delay the others. All accounts
share one 60-second provider deadline, starting before configuration and archive
preflight. Configuration and archive waits share a two-operation capacity limit.
Timed-out or canceled work holds its slot until it ends, so repeated refreshes cannot
queue unbounded preflight work. The remaining deadline limits identity checks and
account requests. A preflight failure clears retained quota because ownership could not
be verified. Cancellation keeps the existing reading. Main-meter normalization
classifies windows by reported duration. Up to 24 hours is session. Longer is weekly.
Primary or secondary position is the fallback only when duration is absent.

Codex account cards show available usage resets. Direct usage reads the authoritative
`rate_limit_reset_credits.available_count` from the same quota response. A positive
count permits one read-only GET to `/backend-api/wham/rate-limit-reset-credits`, using
the same access token and account ID loaded for the quota request. It uses the shared
HTTP transport, no retries, a four-second whole-request deadline, and a separate bounded
timeout-task budget. There is no extra timer, credential reload, token rotation, or
process launch for details. Direct detail rows include only available, unexpired resets.
Missing or invalid expiry dates stay unknown. Accepted dates use `PersistedDateBounds`.
The detail response's count must match the quota count before its rows can be attached.
Missing, malformed, failed, or timed-out details keep valid quota and its reset count,
including on HTTP 401 or 403. They do not trigger auth recovery or retain old expiry
details. Cancellation stops the refresh and preserves the existing reading. Recovery may
also supply detail rows through `rateLimitResetCredits`. Ring cards show the count and
each returned reset's title and time to expiry. Bar cards show the count when collapsed
and reveal the rows when expanded. Expiry rows are sorted by date. A tooltip shows the
exact local date and time. Missing expiry details remain explicit. Reset credits are
display-only. The app never consumes them.

Codex home paths remain the stable settings and pin identifiers. Each observation also
carries an opaque member-and-workspace owner when the local sign-in claims identify
both. Ownership is checked before restoring cached usage and again before publishing a
fetch result. A changed or unreadable sign-in clears the old reading. Normal token
rotation for the same owner preserves offline usage. Missing claims permit current usage
only while the source stays unchanged. Such readings are not persisted. Version-1 Codex
reading archives have no owner and are rebuilt. All credential reads remain bounded and
off-main.

### 4.3 Grok

Grok is opt-in and reads the Grok CLI auth file without writing or refreshing it.
Candidate entries are preference-ordered, then the first valid usable token is selected.
Expired credentials require opening Grok. Usage comes from the CLI billing endpoint and
is shown only in its own popover, Settings, and diagnostics.

## 5. Presentation

Canonical data stores percent used. Presentation defaults to energy left:

```text
percentLeft = clamp(100 - resolved.percentUsed, 0...100)
```

Rings and bars deplete in `left` mode and fill in `used` mode across Claude, Codex,
Cursor, and Grok usage cards. Severity always uses percent used and the configured
warning and critical thresholds. Progression mode does not change policy. Unknown values
render neutral placeholders and never use an empty or tapped-out phrase.

Account presentation combines explicit account staleness, outer reading-state staleness,
and observation age before resolving windows. An expired stale window is unknown. An
expired current window is zero used with no reset time. Selection, card headers, bars,
rings, and spoken summaries use that same rule and one time per render. This is a
derived value. `UsageStore` retains the original observation and timestamp. If several
binding windows have the same kind, cards and the menu bar use the highest usage. The
Codex headline uses that value for the primary window's kind. A failed request and an
old observation remain separate facts. Account errors stay on both card styles.
Secondary-provider cards also show provider failures or stale status.

Reset countdowns use provider-reported reset timestamps minus the current time.
`ResetPhrase` formats these durations. Usage percentages do not change reset timing. The
hero names the most constrained limit window and its reset. Equal usage selects the
later reset. An unknown reset time stays unknown. Changed decision: the earliest reset
from any window no longer supplies the hero's refill text, because a different limit can
still prevent use.

The menu-bar dot uses the highest severity from the selected main provider across all
binding windows of the pinned account, or all of that provider's accounts when unpinned.
Its number follows `menuBarWindow`: short session window by default, long weekly window,
or both. This changes the earlier `nearest` default. The first card now selects the
account, so the window mode has no `nearest`. When the account reports no session value,
the session choice shows the weekly window with a `7d` suffix. The spoken summary names
the weekly window. A missing, invalid, or `nearest` stored value reads as `5h`. A
single-window number may intentionally differ from the all-window dot. Selecting a
provider or account with no reading produces an explicit unavailable or error state,
never fallback.

The menu-bar item exposes one spoken accessibility summary. It names the selected
provider, quota window, percentage used or left, and overall severity separately.
Paused, stale, loading, and unavailable states use explicit words. Stale and paused
summaries omit the percentage.

The popover is 360 points wide with a screen-derived scrolling height. Header controls
are **Settings** and **Quit**. Opening checks reading freshness. There is no separate
refresh button. The selected provider owns the hero. An exact account pin wins.
Otherwise, the account nearest its limit owns the hero, first card, menu bar, and header
time. One "ACCOUNTS" list below the hero holds one card per account for Claude, Codex,
Cursor, and Grok, with no provider section labels. The provider logo names the provider.
There is no provider summary card.

Users choose card order. This changes the earlier fixed order below the first card. The
first card is always the main-meter account, so the first card, hero, menu bar, and
header time agree. The automatic order continues with the selected provider's other
accounts and Claude extra usage, then the other provider's accounts, Cursor, and Grok.
Dragging a card in the popover saves the complete visible order in `popoverCardOrder` at
each move. A move that makes a Claude or Codex account the first card selects that
provider as the main meter and pins that account, through the existing main-meter
settings. After any move, a first card that is not the main meter becomes it, which also
repairs a pin to a removed account. A move that would put Cursor, Grok, or extra usage
first is refused, because they cannot own the menu bar. Appearance has no main-meter
provider or account picker. This changes the earlier picker design. A drag is the only
way to choose. Saved cards keep their saved order. A card with no saved position follows
in the automatic order. A hidden card keeps its saved ID for its return. VoiceOver has
"Move up" and "Move down" actions. **Use automatic order** in **Appearance**, under
**Account cards**, clears the saved order and both account pins, so the first card is
again the selected provider's account nearest its limit. The drag payload is an empty
string, so a drop outside the popover carries no account key. A **Menu bar** label
identifies the selected card. With several eligible accounts, a visible instruction
explains drag-to-top selection. These cues do not change account selection or order.

The Appearance card style applies to every Claude and Codex account card, whatever its
position or provider. Cards use rings or collapsible bars. A bar card shows a session
bar and a weekly bar when the account reports those values. With neither value, one
unknown session bar remains. Each bar has its value and reset time below it. A Claude
bar card shows the name, known plan, session percentage, the bars, and available usage
resets. It expands in place to reveal the Opus and scoped windows with reset timing and
the usage limit resets with their expiry. Claude ring cards also show the usage limit
resets. The provider-wide "Refresh failed" notice and card line use only a failed Claude
refresh. One account's failure, such as an expired login, shows only on that account's
card. Every Claude and Codex bar card expands to show usage limit resets. When the
provider reports no reset allowance for the account, the section says "Not reported" and
shows no count. Each card shows its account error. For the provider that is not
selected, a card also shows a failed provider refresh or stale data. For the selected
provider, these are notices above the hero. With no Claude account rows, a notice states
the refresh failure. Ring cards are always expanded. Bar, Cursor, and Grok cards
remember their expanded state. The header timestamp belongs only to the selected
reading. There is no footer or Add Account button.

Disclosure animates the card layout and popover size together. During collapse, outgoing
details and the larger drawing viewport remain available until the transition finishes.
This keeps lower cards visible as they move up. Rapid clicks replace the current motion
from its visible size. Reduce Motion and hidden popovers apply disclosure changes
without animation.

The native frame driver publishes the matching SwiftUI fitting height at each step.
This replaces holding the old fitting height during growth, which lets the menu bar
host restore an old window size before the transition finishes. Stale frame updates
from an interrupted transition cannot change the replacement.

First-run onboarding pauses polling and directs the user to Settings. Existing users
skip onboarding when a snapshot exists, an attributes-only OAuth lookup finds a
credential, Cursor state exists, or an enabled Codex home has `auth.json` or
`config.toml`. A temporarily unavailable Keychain is not credential evidence. Rendering
onboarding never reads credential contents or secret Keychain data. Startup evidence
checks run off MainActor with five-second waits and two worker slots. A positive probe
ends the search. A blocked credential probe cannot prevent the separate
persisted-observation check from using the remaining slot. The UI shows a loading state
while it checks existing-user evidence. Codex configuration and Settings home checks run
off MainActor with five-second waits and two worker slots. Blocked work retains its slot
until it ends. Only the newest configuration result can update labels and ordering.
Until it resolves, account selection stays unavailable. Opening the popover retries a
failed configuration check. Disabled Codex does no launch path resolution. Opening its
Settings section can request the configuration.

Core `ResetPhrase` formats all reset and refill text for rolling windows. It uses
minutes below one hour and hours below 48 hours. From 48 hours, it uses days and
remaining whole hours, such as `6d 7h`. It omits zero hours. Views never introduce their
own date or weekday formatter.

## 6. Settings

Settings uses a custom tab bar with **Data**, **Appearance**, **Advanced**, and
**About**. Command-1 through Command-4 open these tabs. Tabs and Appearance options
expose their selected accessibility state. Appearance includes the visual warning and
critical thresholds; arrow keys adjust a focused threshold slider by its existing step.
Manual OAuth entry always offers **Cancel**, including during reauthentication. Cancel
clears the draft tokens and their visibility, returns to the previous setup screen, and
does not change the stored credentials or connection mode.
`MeterSettings` reads and writes standard defaults.

| Key | Domain value | Default |
| --- | --- | --- |
| `cardStyle` | `rings`, `bars` | `rings` |
| `progressionMode` | `left`, `used` | `left` |
| `mainMeterProvider` | `claude` or `codex`, set by a drag to the top | `claude` |
| `menuBarAccount` | nearest or Claude account key, set by a drag | nearest |
| `codexMainMeterAccount` | nearest or Codex home ID, set by a drag | nearest |
| `popoverCardOrder` | card IDs in dragged order | empty (automatic) |
| `menuBarWindow` | `5h`, `7d`, `both` | `5h` |
| warning threshold | percent used | 80 |
| critical threshold | percent used | 95 |
| stale interval | seconds, 600 through 24 h | 600 |

Startup and Appearance settings replace an invalid menu-bar mode, including the old
`forecast` value and the removed `nearest` value, with `5h` in standard defaults.

Account names and plans accept user overrides. A name override takes precedence over the
friendly config label. A plan override takes precedence over the account OAuth plan.
Configured paths are canonicalized and account disabling never removes the default
account.

### Upgrade cleanup

The minimum supported upgrade version for 4.0 is 3.0. Every 3.x release retains each
migration, its completion key, the App Group snapshot import, and old snapshot decoding.
No 3.x release deletes, renames, or resets an earlier completion key. Version 4.0
removes code needed only by 2.x installations. The 4.0 release lets a 2.x installation
get the last 3.x release first. Its release notes state that upgrade requirement.

`LegacyAttentionHookMigration` removes the six exact historical Claude Meter hook
commands from `hooks.Stop`, `hooks.Notification`, and `hooks.StopFailure`. It runs
off-main once at launch, including when usage polling is paused or its sources are
disabled. It scans the previous config scope: `~/.claude`, plausible immediate
`~/.claude-*` directories, and configured paths. Disabled accounts and paths with equal
account keys are included.

The migration preserves user hooks, group metadata, `statusLine`, and unrelated
settings. It uses bounded settings reads and atomic writes, and writes only after
removing an exact command match. Missing files need no write. Invalid or inaccessible
settings leave `didRemoveLegacyAttentionHooks.v2` unset so a later launch can retry. The
key is set in standard defaults only after all discovered config paths and event cleanup
succeed. The v2 pass also runs on installations with the old v1 completion key, because
v1 could silently leave event files behind after a deletion failure.

After config cleanup succeeds, the migration removes old files under
`~/.claude-meter/events`. It follows no directory links and can leave empty directories.
Deletion failures or unsafe linked roots leave cleanup incomplete for a later retry. It
preserves `sessions` and `statusline.json` and creates no event storage or watchers.

`LegacyStatuslineMigration` runs after the attention migration at launch. It removes
only five exact known leading shell snippets: owner-only per-account, pre-umask
per-account, sanitized flat session, unsanitized flat session, and original single-file
capture. Repeated prefixes are removed. The remaining user command is preserved exactly.
A standalone capture command becomes an empty command. Other `statusLine` fields remain.

The previous installer forced `statusLine.refreshInterval` to 1 but saved no prior
value. The migration preserves the current interval because its ownership cannot be
determined. It performs no new installation, repair, or interval change. Missing files
are harmless. Malformed settings stay unchanged. It checks the same config scope as hook
cleanup, including disabled accounts and paths with duplicate account keys. It writes
only changed settings and preserves settings symlinks through atomic writes to their
resolved targets.

After all settings are handled, it removes captured files under
`~/.claude-meter/sessions`, `~/.claude-meter/statusline.json`, and numeric `.sl-*`
temporary files. It follows no links, checks directory and entry identity before
deletion, and may leave empty directories. Errors leave
`didRemoveLegacyStatuslineBridge.v1` unset for a later launch. Only successful settings
and captured-file cleanup set that key in standard defaults. No periodic bridge work
remains. A running Claude Code process that cached its old command may need a restart to
load the changed settings.

`LegacyArtifactCleanupMigration` runs after the hook and statusline attempts and a
bounded App Group snapshot import on Claude's existing storage queue. All three existing
completion keys must be true before it removes anything. Import errors preserve the
source for retry. Migration failures are logged and do not stop application startup.
Provider restoration can request the same import on that queue. There is no second
importer that could race an accepted snapshot write.

The cleanup owns exactly these files under the user's home:

- `Library/Application Support/ClaudeMeter/cost-usage-cache.json`
- `Library/Caches/com.jewei.claudemeter/models-dev-pricing-v1.json`
- `Library/Group Containers/group.com.jewei.claudemeter/Library/Application
  Support/ClaudeMeter/main-meter.json`
- `Library/Application Support/ClaudeMeter/main-meter.json` (the former non-App-Group
  fallback)
- `Library/Group Containers/group.com.jewei.claudemeter/Library/Application
  Support/ClaudeMeter/current.json`
- `Library/Group Containers/group.com.jewei.claudemeter/Library/Application
  Support/ClaudeMeter/last-error.json`
- `Library/Application Support/ClaudeMeter/usage-history.jsonl`

Usage-history cleanup retains the old deletion behavior through this one versioned
owner. It no longer runs as a separate unversioned task. The cleanup never removes
current Application Support snapshots or errors, standard defaults, credentials, or
unknown neighboring files. Statusline and attention storage keep their existing
migration owners. The two old shared-defaults plists remain because an independently
installed older app or widget and the preferences service can still hold their values.
The current app and its bundle have no consumer of these defaults. The historical
emergency store also used generic `current.json`, `main-meter.json`, and
`last-error.json` names in the user's temporary directory. These ambiguous paths are not
cleanup targets.

Cleanup traverses each path from an open home directory with no-follow directory
descriptors. It accepts only regular final files, checks directory and entry identity,
and unlinks only that entry. It never reads cache contents or recursively deletes
directories. Links, special files, and filesystem errors leave cleanup incomplete.
Independent files can still be removed on a partial failure. All seven files must be
removed or proven absent before standard defaults records
`didCleanupObsoleteArtifacts.v1`. The completed path returns after that defaults check,
with no directory scan. Tests use isolated homes and defaults. Hosted tests cannot
invoke live cleanup.

## 7. Networking, Keychain, and diagnostics

OAuth and other direct provider requests use `ProviderHTTPClient.shared` or an injected
`HTTPTransport`. The provider session is ephemeral and cookie-less. It has a ten-second
idle timeout, an eight-MiB response cap, and a 30-second hard deadline for the complete
send, including retry waits. A chunk receiver rejects an oversized declared
`Content-Length` before body receipt and cancels a streamed response when it crosses the
cap. A dedicated timeout-task budget bounds cancellation-ignoring work. The session
refuses redirects that change HTTPS origin. Transient retry applies only to idempotent
methods and bounded, finite delays. OAuth handles HTTP 429 separately. Client-generated
exponential backoff is capped at eight seconds. A valid server `Retry-After` is not
shortened. If the wait cannot fit within the remaining send deadline, the client returns
the original response without another attempt. Changed decision: the eight-second cap
previously also shortened server guidance. Non-positive retry values retain the existing
fallback behavior, and the separate OAuth 429 gate is unchanged.

All Security.framework calls pass through `KeychainGateway`, which disables interaction
and fails closed in test processes unless live Keychain testing is explicitly enabled.
Candidate selection is deterministic on equal timestamps. Secret reads occur only after
explicit user action or during an enabled provider poll.

All errors are sanitized at UI and persistence boundaries. Sanitization redacts emails,
home paths, UUIDs, bearer values, JWTs, provider tokens, session keys, and labeled
sensitive fields.

`MeterLog` handles all logging. It sanitizes every message before the text reaches
`os.Logger` or the log file, so a call site cannot leak a secret by forgetting to
sanitize. Categories are app, poll, and oauth. The log file is opt-in through
**Advanced** settings. The file uses `0600` permissions in
`~/Library/Logs/ClaudeMeter/`, a `0700` directory. It rotates once at 4 MiB. Turning off
the setting deletes the file. Diagnostics keep showing present state only.

## 8. Verification and release

`./scripts/verify-local.sh` runs the local and CI checks. It runs strict Swift
formatting checks, all Core and Provider package tests, hosted app tests, and unsigned
Debug and Release app builds. The Xcode project and the committed workspace resolution
pin Sparkle exactly.

Tests use isolated data. Temporary directories are unique and cleaned up. Wall clocks
and defaults are injectable where policy depends on them. Tests never read live Keychain
or Application Support data by default. Hosted app tests and the opt-in presentation
benchmark construct an empty provider store and skip production startup services and
file logging. The synthetic benchmark is separate from the normal checks. Its procedure
and limits are in [docs/performance.md](docs/performance.md).

A release publishes the signed GitHub assets before it pushes the new `appcast.xml` to
`main`, so the feed never points at a missing artifact. Releases require a clean source
commit, signing, notarization, matching debug symbols, DMG integrity, matching feed
metadata, and the local verification gate. Publication completes after the assets and
feed are public and the staging branch is removed. Manual platform and live Sparkle
update tests are optional for all releases, including major and migration releases. No
separate test host or report is required. [docs/releases.md](docs/releases.md) defines
the procedure.
