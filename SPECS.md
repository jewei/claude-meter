# Claude Meter specification

This document defines current user-visible behavior and stable system boundaries.
Development rules belong in the root and directory-level `AGENTS.md` files. Visual tokens
and component treatment belong in `DESIGN.md`. Removed features are not part of this spec.

## 1. Product contract

Claude Meter is a macOS 14+ menu-bar app for viewing coding quota as energy
remaining. It has no Dock icon (`LSUIElement = YES`) and uses a SwiftUI
`MenuBarExtra` with `.window` style. Claude remains the default main meter for existing
users; users can explicitly select Claude or Codex. Cursor and Grok remain secondary
popover sources.

The app is local-first:

- Provider credentials are read-only except for manually entered Claude OAuth tokens,
  which Claude Meter owns in Keychain.
- Provider secrets are never rendered, logged, or copied into diagnostics.
- Quota polling reads provider data. It does not scan local
  transcripts or estimate historical costs. Provider-reported live balances remain visible.
- Only the explicitly selected main provider affects the hero, first popover section,
  menu-bar indicator or header timestamp. Missing selected data never falls
  back to another provider.

## 2. Targets and ownership

| Target | Responsibility |
| --- | --- |
| `ClaudeMeter` | AppKit/SwiftUI presentation, settings, refresh scheduling, display sleep/wake, Sparkle |
| `ClaudeMeterCore` | Normalized snapshot models, storage, thresholds, reset formatting; no UI or provider I/O |
| `ClaudeMeterProviders` | OAuth/Keychain/HTTP and all four provider adapters |

The app depends on Core and Providers. Providers depends on Core. Provider-specific wire formats do not enter Core.

`AppState` is the main-actor composition root and presentation/settings coordinator.
`RefreshScheduler` owns global timing and admission through explicit `RefreshConfiguration`.
All provider usage lifecycle belongs to `UsageStore`,
which publishes Core `ReadingState<ProviderSnapshot>`. AppState owns no mutable provider readings.
`MainMeterReading` holds the selected provider quota data for app presentation. It is not
persisted.

### Shared provider domain

`ProviderSnapshot` is the application-domain boundary for all four providers. It holds a
`ProviderID`, an account array, and the latest included quota observation time. It has no
selected or active account. Each `ProviderAccountSnapshot` keeps its own optional observation time,
explicit stale flag, sanitized last error and last attempt time. A nil observation means
that the configured account has no usable data. Age-based staleness remains a consumer policy.

Each account has a label, optional plan and public subtitle, ordinary `UsageWindow` rows,
and `BalanceItem` rows. Window percentages always mean used, from 0 through 100. Adapters
clamp finite values and keep unknown or non-finite values unknown. An over-limit flag
preserves severity after clamping. Window kinds support session/weekly menu-bar choices;
`contributesToQuota` excludes display-only scoped windows and budget rows from selection.
Only provider-reported reset/end times enter `resetAt`.

`UsageWindow.resolved` uses the existing `LimitWindow` reset rule. A current expired
window becomes zero with no next reset date. A stale expired window becomes unknown.
Resolution does not replace the stored authoritative timestamp. Presentation converts
used percentage to energy left. Account selection takes an exact pin, or the greatest
resolved quota usage. Ties retain input order. Unknown usage ranks below known zero.

| Provider output | Domain mapping | Account identity |
| --- | --- | --- |
| Claude snapshot/account array | Session, weekly, Opus and other scoped windows; plan, email subtitle; extra-usage amount, limit, currency and paused state | Existing config account key, including the existing unmapped OAuth key; never email |
| Codex reading per home | Session/weekly windows classified by duration; plan, credits and reset allowances | Existing canonical home path used by account pins |
| Cursor usage | Authoritative billing percentage, optional Auto/API rows, billing end, plan and period spend/limit | `default`, a provider-local connection slot |
| Grok usage | Credit percentage, reported period end, on-demand spend/cap and prepaid balance | `default`, a provider-local connection slot |

Cursor and Grok output no opaque member ID or reliable plan for Grok. Their slot keys do
not prove login ownership. Providers keep an internal, in-memory SHA-256 credential
stamp for each accepted reading. Validation clears previous readings when the source
credential changes. A read-only check after each request rejects a response or stale
retention from a changed source. The stamp never enters ProviderSnapshot, diagnostics,
or disk storage. Without a stable member ID, token renewal also invalidates the old
reading until the new credential succeeds. Metadata-only changes do not change the stamp.
Codex member/workspace ownership checks still guard last-good restoration and publication;
the home key alone is not sufficient. No token or credential fingerprint enters the domain.
Codex email stays omitted. Claude email is display text only, as in the existing cards.

Balance amounts use `Decimal` in the stated unit. They need not be money. Optional limits
retain live spend/budget pairs. `displayText` retains non-numeric states such as unlimited
credits and paused extra usage. Counted allowances have an authoritative total plus
optional title/expiry details. Detail count never replaces the total. Codex reset-credit
expiry is separate from a quota reset; it does not advance quota freshness.

The provider module has one adapter per provider. Authentication, raw source/parser
metadata and raw errors stay outside `ProviderSnapshot`. Sanitized account error text
belongs to the account. `ReadingState` lives in Core with current/stale/failed cases.
A failed reading can include a snapshot of unavailable account labels and errors. It has
no successful poll time and no account observations. This preserves error cards without
inventing quota or maintaining another account array.

`AppState.normalizedSnapshots` reads UsageStore and applies account display overrides.
It performs no I/O and stores no second copy. All provider cards consume normalized
accounts, windows and balances. Existing Claude and Codex disk formats remain internal
to their provider boundaries.

### Provider lifecycle store

Core's `UsageProvider` has explicit validation, fetch and acceptance stages:

1. `validatePrevious(_:now:refreshID:)` returns reconciled previous accounts.
2. `fetch(now:previous:refreshID:)` returns a `ProviderSnapshot`.
3. `didAccept(_:refreshID:)` updates in-memory metadata and enqueues ordered persistence.
4. `waitForPersistence()` asynchronously waits for already accepted writes.

UsageStore supplies the same refresh ID to validation, fetch and acceptance. It checks the active token,
enabled state and cancellation before reconciliation, after reconciliation, before fetch,
and after fetch. It publishes a changed reconciled value before fetching. An unchanged
value keeps its existing outer reading error/freshness. A nil reconciled value clears it.
The store checks the token, accepts through `didAccept`, then publishes the final value
without suspension. This orders ownership stamps and diagnostics before observation.
Disk success is not a condition for publication. MainActor acceptance must perform no
blocking I/O, including Foundation file operations, Keychain calls or subprocess waits.
It may only update memory and submit work to a provider-owned queue.

After publication, the store clears loading and awaits `waitForPersistence`. This async
wait performs no blocking I/O on MainActor. A newer refresh sees the accepted snapshot
immediately. Cancellation, supersession or disable before acceptance prevents a save.
After acceptance, these events do not revoke the queued write. A thrown fetch failure
cannot overwrite last-good data. No later state publication occurs after the write wait.
Providers never call back into publication and return no side-effect closures.

Cursor/Grok validate credential ownership and accept an in-memory owner stamp. Persistence
waits remain no-ops. Their
only concrete lifecycle method fetches a normalized snapshot. Claude and Codex each keep at most one
pending preflight record and one pending save record, identified by refresh ID. These
records carry existing archive data, source diagnostics and account checks across
stages. They are consumed by fetch/commit or replaced at the next reconciliation; they
never supply an independent last-good usage cache. Old stages cannot replace newer
records. Repeated acceptance of the same result performs no second save.

Codex resolves configured home paths off-main during validation. Archive reads are
async, and cancellation/refresh ownership is checked again after each suspended step.
Codex submits each accepted archive to one serial queue before publication. Encoding,
UserDefaults reads and UserDefaults writes run there. B cannot write before an earlier
accepted A finishes. The reading store retains only the newest pending archive until
its write wait completes. A new refresh can validate this archive during a slow write;
it cannot restore an older disk value over the accepted observation. This temporary
write buffer preserves raw archive fields without adding a second usage-state owner.
Archive format, ownership validation, and email/fingerprint exclusions are unchanged.

Refresh operations await their accepted writes, without blocking presentation or the
main thread. There is no detached persistence task or shutdown daemon. Process exit can
still interrupt an outstanding write. The app does not add a quit delay or a durability
guarantee beyond existing storage; the next launch can fetch usage again.

`UsageStore` is an `@MainActor` observable application type, built with an explicit array
of providers indexed by ID. It owns the only mutable provider reading dictionary,
the refreshing set, and active refresh tasks. Main-actor work coordinates publication.
Cursor/Grok fetches use the existing detached 60-second timeout. Codex owns its 60-second
batch deadline and bounded workers. Claude owns its discovery, primary OAuth and secondary
account deadlines. Neither has a redundant outer timeout. All admitted
providers start before the store awaits their results. Failures remain independent.

RefreshScheduler owns the global timer and display sleep/wake handling.
It sends the admitted provider set to one UsageStore refresh call. Store observation forwards through
AppState to the existing views; there is no copied store state or event stream. The store
has no disk persistence.

A success publishes a current reading with the snapshot's observation time. A transient
failure retains the complete previous snapshot and successful timestamp as stale. Without
a previous usable value, it publishes failed. Unknown percentages remain nil. Source
account freshness is unchanged by the store: effective staleness is outer reading stale
or account stale. Current Claude and Codex provider readings can have mixed account ages.
Age-based display staleness still uses the existing threshold.

Codex uses current configuration for each refresh. Each home succeeds, retains an
ownership-validated previous observation as stale, or becomes unavailable with an account
error. If any account has usable data, the provider reading is current. This includes an
all-stale but still valid account set. If none has usable data, the reading is failed and
retains only unavailable account details. Failure never advances an account observation
time. Exact pins cannot substitute a different account. Nearest selection excludes
unavailable accounts and resolves stale reset windows to unknown after expiry.

Each provider refresh has one token. A newer request cancels the old task and replaces its
token. Only the current token can publish or clear loading. Caller cancellation affects
only that caller's requests; it does not record a failure or cancel a newer task. Disable
cancels the active task, removes the reading and blocks late publication, including across
re-enable. Pause and display sleep cancel store work through the same API.

Provider adapters sanitize errors and classify last-good retention. Cursor missing,
unauthorized or forbidden credentials clear its value while retaining the last successful
timestamp. Temporary errors preserve last-good data only while its credential owner remains valid.
Missing or expired Grok credentials clear previous usage. A temporary credential read
failure can retain the accepted reading when no source change has been observed.
Cancellation passes through without becoming a provider failure.

Cursor/Grok cards now read normalized windows and balances. Cursor keeps its total and
Auto/API percentages, plan, billing reset and spend text. Its limit stays available in the
balance but does not form a displayed ratio because bonus credit affects the percentage.
Grok keeps its credit percentage, reset and on-demand spend/cap text. Prepaid balance stays
in the snapshot; this phase adds no new card row. Metadata visibility and card layout stay
unchanged. Settings credential preflight remains separate from quota fetching.

### Global refresh scheduler

`@MainActor RefreshScheduler` owns one asynchronous timer, queued requests and PowerMonitor.
AppState supplies only active state and enabled provider IDs. It combines onboarding and
pause state before supplying configuration. Scheduler forwards enable/disable to UsageStore
and never reads UserDefaults. It owns no provider values, credentials or storage.

- Start/resume refreshes enabled providers immediately once onboarding permits it.
- Every 300 s while awake, all enabled providers share one background refresh opportunity.
  Provider work already in progress is not duplicated. There is no main/secondary provider
  distinction and no battery-dependent cadence.
- Popover open refreshes only missing, failed, provider-stale or at least 60 s old readings.
  Core's `ReadingState<ProviderSnapshot>.needsRefresh` uses the successful observation time.
  Invalid or future dates also request refresh. Account-level freshness remains provider-owned.
- Explicit manual refresh bypasses the age check and can supersede current work.
- Enabling a provider refreshes only that provider. Disabling cancels it and clears its
  reading. Credentials/account/source changes invalidate and refresh only the affected
  provider. These actions do not restart the timer or refresh unrelated providers.
- Display sleep cancels the timer, queued requests and active store work. There are no periodic asleep checks. Wake refreshes missing, failed, stale or
  at least 300 s old readings, then starts a new 300 s timer. Recent data needs no extra fetch.
- Network changes do not trigger refresh. Normal cycles, popover open and manual refresh
  handle recovery. Authentication retries and backoff remain provider-owned.

Requests from the same actor turn merge into a provider set. UsageStore owns execution,
supersession and publication safety. The scheduler has no global cycle IDs or mutable copy
of provider readings. Pause/stop reject queued and late timer work.

Reset countdowns need no provider request. The popover updates its local time each second
while visible and cancels that timer when closed. UI age staleness uses 600 s by default,
with a minimum of 600 s for older settings and a maximum of 24 h. This leaves a full normal
refresh interval of headroom. Explicit provider/account failure can mark data stale sooner.
The 60 s interactive threshold is independent from this display threshold.

## 3. Claude provider

Claude configuration flows through `ClaudeProviderAdapter`, OAuth usage and account
reconciliation, then into one normalized `ProviderSnapshot` in UsageStore. The adapter
uses the existing `OAuthPipeline` for the primary account and `MultiAccountOAuth` for
secondary accounts. These internal clients return data only. The app does not consume
`ParseResult`, `ClaudeUsageSnapshot`, or mirrored top-level account fields.

Validation reads a legacy last-good snapshot off-main when needed, removes disabled
accounts, and clears expired stale windows. A change between auto and manual mode
invalidates previous usage before fetching. UsageStore publishes validated state only
after its refresh-token check. Failed primary or secondary requests retain valid previous
accounts as stale with their original observation times. An account without previous data
remains visible with unknown windows and a sanitized error. A mixed fresh/stale/unavailable
set is current when at least one account has usable data; an entirely unavailable set is
failed. A successful account response replaces all its fields.

The adapter owns a 5 s discovery bound, a 60 s primary bound and the existing 30 s secondary
batch bound. `ownsDeadline` prevents a redundant UsageStore timeout. Typed source attempts,
credential issues, account failures and duplicate-login metadata remain read-only provider
diagnostics. Only sanitized account failure copy enters the normalized reading.

Fetch results control current, stale and failed presentation. There is no separate
service-status request. Global refresh policy is defined above; Claude account timing
and authentication backoff remain inside the provider.

### 3.1 OAuth

OAuth is used only when mode is `auto` or `manual`.

- Auto mode reads Claude Code's legacy or hashed Keychain credential entries after the
  user explicitly confirms Connect. Settings preflight is attributes-only.
- Manual mode stores an app-owned Keychain item and reports save/delete failures.
- Automatic mode never consumes refresh tokens or writes Claude Code credentials. It uses
  access tokens until expiry. Expiry or rejection requires renewal in Claude Code; previous
  usage stays stale. The next poll reads the renewed credential.
- Manual mode can rotate tokens, cache them, and save them to its app-owned Keychain item.
- Automatic credentials retain the exact Keychain service through reads and cache reuse.
  Each usage response belongs to its mapped config account. An unmapped login keeps a
  separate account key. Manual mode supplies the default account slot.
- Concurrent manual refreshes share one request. A bounded handoff retains the result for late
  callers that selected the same one-use token before it was rotated. Credential-generation
  keys prevent a replacement login from using an older result.
- Refresh failure clears the corresponding in-memory credential cache.
- Disconnect revokes the current credential generation before an in-flight refresh can
  restore cache or manual Keychain state. A disabled source cancels and rejects an
  in-flight connection result; verification never turns the source back on.
- All usage and refresh requests use the shared cookie-less transport with same-origin
  HTTPS redirect enforcement.
- The process-wide 429 gate is shared by polling, verification, and per-account requests. It honors
  positive `Retry-After` delta or HTTP-date values up to a 24-hour safety maximum. This
  maximum prevents an invalid server value from disabling OAuth for the life of the app.
  App startup restores one provider-wide deadline from standard defaults. The record
  contains no credentials, survives restarts, and is never extended by loading it.
  Invalid/expired records and clock changes that imply more than 24 hours remaining
  are rejected. Storage failure preserves the in-memory block. Test app initializers
  do not install persistence. Interactive refresh and account changes never bypass it.

The usage response maps `five_hour`, `seven_day`, `seven_day_opus`, dynamic scoped weekly
limits, `extra_usage`, and plan metadata. Flat scoped fields win over equivalent entries
in `limits[]`; unknown/null windows degrade without failing the whole response. Extra
usage minor units are scaled by the response's decimal places.

A successful OAuth response replaces one complete account observation, including absent
optional fields. There is no second enrichment request. The primary credential is excluded from the secondary request batch. Only manual
credentials have a token refresh path.

Multi-account OAuth runs only in auto mode. It reads each configured directory's
namespaced credential and local account identity. Secondary accounts retain the existing
five-minute request interval and read-only credential behavior; expired secondary tokens
require a new Claude login. Each reading keeps its actual fetch time. Failed enabled
accounts retain stale last-good data; expired retained windows become unknown. An exact
main-meter account pin wins; otherwise the account nearest its limit is selected. No
session files, file activity, or Claude Code process activity influence selection.

Secondary request times are provider metadata, not a usage cache. Accounts not due keep
UsageStore's previous normalized observation and timestamp. The shared 429 gate and token
rotation remain independent of refresh acceptance. Interactive refresh cannot bypass them.

Optional Claude web reset offers and the separate web sign-in are removed. They reported
reset grants, not usage, balance or authoritative quota reset times.

### 3.2 Snapshot and staleness

`ClaudeReadingStore` owns legacy snapshot I/O. `SnapshotStore` atomically writes Claude's
`current.json` and sanitized `last-error.json` under
`~/Library/Application Support/ClaudeMeter/`. Writes follow account assembly and
UsageStore acceptance. Validation, store creation, upgrade import and writes run on one
provider-local serial queue. The queue preserves accepted write order. UsageStore publishes
before awaiting disk completion. A rejected result cannot write; cancellation after acceptance
does not revoke a queued write. Bounded reads, atomic writes and per-store circuit breakers
also apply to restoration. Startup onboarding can check this archive asynchronously for
existing-user evidence without taking ownership of usage state.

On upgrade, a one-time import checks the former
`~/Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter/current.json`.
It imports only a newer usage observation, or fills an empty local store. A successful
check sets `didImportLegacyAppGroupSnapshot.v1` in standard defaults. Read/write errors
leave the key unset for a later launch. The import does not delete legacy files or
copy the old widget publication or error record. Startup also requests this import
through the same Claude storage queue when Claude is disabled. A separate cleanup
may remove the legacy source only after this completion key is set.

`lastSuccessfulPollAt` changes only after a usable successful poll. Data is stale after
600 seconds by default unless explicitly marked stale earlier. Claude notices use Claude staleness;
an optional provider's stale state cannot make the Claude card stale.

Top-level fields mirror the first account only at the legacy persistence boundary. Each account
has its own quota, metadata, observation time, and stale flag. Old JSON session, activity,
and analytics fields are ignored. Old statusline snapshots are marked stale when read;
the first successful OAuth response replaces that account's observation.

Expired rolling windows resolve to 0% used and no reset date. Consumers must call
`UsageWindow.resolved(asOf:isStale:)` before display or policy evaluation. Stale expired
windows become unknown instead of zero.

## 4. Optional providers

### 4.1 Cursor

Cursor is opt-in. Each credential read opens its known `state.vscdb` path through
macOS system SQLite, binds four ItemTable keys in one SELECT, then finalizes and closes.
The SDK module links libsqlite3; no external package or executable is required.
Open flags are `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`, with `readonly_shm=1`.
SQLite handles committed WAL data with normal locking; immutable mode is never used.
The reader does not write the database or create/repair sidecars. A WAL database that
needs missing sidecars fails cleanly instead. See the
[SQLite WAL read-only rules](https://www.sqlite.org/wal.html) and
[Unix VFS read-only SHM behavior](https://github.com/sqlite/sqlite/blob/master/src/os_unix.c).

Regular-file checks reject devices/FIFOs at the DB and existing sidecars. No file
identity cache or SHM-header inspection remains. Reads run off-main under the existing
provider timeout; Settings also uses a detached task. SQLite gets a 1 MiB row limit,
no busy wait, and a cancellation progress handler. Temporary busy/locked/read failures
retain last-good usage if the existing Keychain fallback cannot supply credentials.
Missing credentials still require sign-in. Errors contain no raw SQLite paths.

UTF-8, ASCII UTF-16LE blobs and BOM-marked UTF-16 values are decoded before the existing
whitespace/quote removal. Missing access or refresh values use the read-only, no-UI
Keychain gateway independently. No detection result is cached.
Cursor never consumes refresh tokens, caches rotated credentials, or writes credentials.
It reads the current access token for each request. Known expired tokens are not sent;
unknown expiry permits a usage request. Expiry or HTTP 401 requires opening Cursor to
renew the login. Transport and server failures remain temporary errors. Cursor errors
and staleness appear only on its popover/settings/diagnostics surfaces.

### 4.2 Codex

Malformed optional credit, reset, or plan metadata does not discard valid quota windows.
Unusable metadata stays unknown. A valid reset count remains available when optional
detail rows cannot be decoded. Direct OAuth quota decoding remains strict.

Codex is opt-in and supports one implicit `CODEX_HOME` plus explicitly configured homes.
Each home has its own display name and quota observation. Normal refresh reads access
credentials from that home's `auth.json` and makes one direct HTTP usage request. When
that response reports available usage resets, it also requests their expiry details.
It starts no Codex process. There is no source picker; old `codexSourceMode` values are ignored.

Claude Meter never consumes the Codex refresh token, rotates Codex credentials, or writes
Codex auth storage. Codex owns that state. Upstream Codex reloads credentials before a
managed refresh, exchanges the refresh token, and saves rotated tokens through its selected
backend. Supported backends include file, OS keyring, automatic selection, and process-local
memory. A new subprocess cannot recover another process's memory-only login.
See [OpenAI authentication documentation](https://learn.chatgpt.com/docs/auth) and the
[reviewed upstream implementation](https://github.com/openai/codex/blob/30fc6864cc1318121eca1843c217fe00ce1212f1/codex-rs/login/src/auth/manager.rs).

Recovery is permitted only for these typed direct failures:

- `CodexOAuthCredentialsError.notFound`, `missingTokens`, `decodeFailed`, `unreadable`,
  or `expiredAccessToken`.
- `CodexUsageError.loginRequired`, produced by HTTP 401/403 from the quota request.

A numeric access-token JWT expiry within 60 seconds skips the direct request. Parsing is
bounded to 64 KiB and accepted date bounds. Malformed, absent or nonnumeric expiry means
unknown, so direct HTTP is attempted. Unverified claims are never authentication proof.
Network/DNS failures, timeouts, HTTP 429/5xx, decoding errors and missing quota do not
launch recovery. They keep normal last-good stale behavior. API-key auth shows unavailable
subscription quota and cannot retain an earlier subscription observation.
An explicit `auth_mode: "chatgpt"` takes precedence over a stored `OPENAI_API_KEY`.
That mode requires OAuth tokens; missing tokens permit credential recovery. Explicit
API-key mode still rejects subscription quota even when old OAuth tokens remain.
Without an explicit ChatGPT mode, a nonempty API key selects API-key auth.
See [upstream mode resolution](https://github.com/openai/codex/blob/7dae8c53d97e61cd774e4d6bcca5243c29ca615c/codex-rs/login/src/auth/manager.rs#L1763-L1780).

Recovery resolves Codex, launches one `codex app-server`, initializes, reads the account
with `refreshToken: true`, then reads rate limits. Codex handles any credential rotation
and backend writes. A successful result, error, timeout or cancellation awaits process
termination and reaping before the source returns. Startup and individual requests keep
5-second deadlines. Shutdown uses TERM, then SIGKILL after 0.25 seconds if needed, on a
separate queue. Environment scrubbing, bounded protocol output and SIGPIPE protection remain.
No process pool, idle eviction, executable cache or application shutdown hook remains.

Source/auth-mode metadata remains in provider diagnostics and the compatible Codex archive;
ProviderSnapshot has no source implementation fields. When recovery also fails, both failure
reasons remain available for sanitized diagnostics. Account metadata is optional, but a
reported API-key mode stops the subscription quota request.

Last-good readings are persisted per resolved Codex home, without account email, and are
restored after ownership checks on the first refresh. `CodexProviderAdapter` owns restore
and save work; UsageStore accepts the save with final publication. A failed refresh retains that reading and records the attempt error/time
separately from the last-success time; observation staleness remains age-based. Healthy
accounts continue updating when another account fails. Accounts run in batches of three,
but all batches share one 60-second provider deadline. Main-meter normalization classifies
windows by reported duration (up to 24 hours is short/session; longer is weekly), falling back
to primary/secondary position only when duration is absent.

Codex account cards show available usage resets. Direct usage reads the authoritative
`rate_limit_reset_credits.available_count` from the same quota response. A positive count
permits one read-only GET to `/backend-api/wham/rate-limit-reset-credits`, using the same
access token and account ID loaded for the quota request. It uses the shared HTTP transport,
no retries, a four-second whole-request deadline, and a separate bounded timeout-task budget.
There is no extra timer, credential reload, token rotation, or process launch for details.
Direct detail rows include only available, unexpired resets. Missing or invalid expiry dates stay unknown;
accepted dates use `PersistedDateBounds`. The detail response's count must match the quota
count before its rows can be attached. Missing, malformed, failed, or timed-out details keep
valid quota and its reset count, including on HTTP 401/403. They do not trigger auth recovery
or retain old expiry details. Cancellation stops the refresh and preserves the existing reading.
Recovery may also supply detail rows through `rateLimitResetCredits`. Ring cards show the
count and each returned reset's title and time to expiry. Bar cards show the count
when collapsed and reveal the rows when expanded. Expiry rows are sorted by date; a tooltip
shows the exact local date and time. Missing expiry details remain explicit. Reset credits
are display-only; the app never consumes them.

Codex home paths remain the stable settings and pin identifiers. Each observation
also carries an opaque member-and-workspace owner when the local sign-in claims
identify both. Ownership is checked before restoring cached usage and again before
publishing a fetch result. A changed or unreadable sign-in clears the old reading.
Normal token rotation for the same owner preserves offline usage. Missing claims
permit current usage only while the source stays unchanged; such readings are not
persisted. Version-1 Codex reading archives have no owner and are rebuilt. All credential
reads remain bounded and off-main.

### 4.3 Grok

Grok is opt-in and reads the Grok CLI auth file without writing or refreshing it. Candidate
entries are preference-ordered, then the first valid usable token is selected. Expired
credentials require opening Grok. Usage comes from the CLI billing endpoint and is shown
only in its own popover/settings/diagnostics surfaces.

## 5. Presentation

Canonical data stores percent used. Presentation defaults to energy remaining:

```text
percentLeft = clamp(100 - resolved.percentUsed, 0...100)
```

Rings and bars deplete in `left` mode and fill in `used` mode across Claude, Codex,
Cursor, and Grok usage cards.
Severity always uses percent used and the configured warning/critical thresholds;
progression mode does not change policy. Unknown values render neutral placeholders and
never use an empty/tapped-out phrase.

Reset countdowns use provider-reported reset timestamps minus the current time.
`ResetPhrase` formats these durations. Usage percentages do not change reset timing.

The menu-bar dot uses the highest severity from the selected main provider across all
binding windows of the pinned account, or all of that provider's accounts when unpinned.
Its number follows `menuBarWindow`: nearest, short/session, long/weekly, or both.
A single-window number may intentionally differ from the all-window dot. Selecting
a provider or account with no reading produces an explicit unavailable/error state,
never fallback.

The menu-bar item exposes one spoken accessibility summary. It names the selected
provider, quota window, percentage used/left, and overall severity separately. Paused,
stale, loading, and unavailable states use explicit words; stale and paused summaries
omit the percentage.

The popover is 360 points wide with a screen-derived scrolling height. Header controls
are Settings and Quit. Opening checks reading freshness; there is no separate refresh button.
The selected provider owns the hero and first account section. An exact account pin wins;
otherwise the account nearest its limit owns every primary surface. The other eligible
provider remains visible below as one compact secondary summary. When Claude is secondary,
the summary shows the nearest account's plan when known and expands in place to reveal each
account's session, weekly, Opus/scoped windows, reset timing, and known identity metadata.
The secondary Codex summary also expands to show each account's limits and usage limit resets.
Primary Claude and Codex ring cards are always expanded. Codex bar cards, secondary summaries,
Cursor, and Grok cards remember their expanded state.
The header timestamp belongs only to the selected reading. There is no footer or Add Account button.

First-run onboarding pauses polling and directs the user to Settings. Existing users skip
onboarding when a snapshot exists, an attributes-only OAuth lookup finds a credential, Cursor
state exists, or an enabled Codex home has `auth.json`/`config.toml`. A temporarily unavailable Keychain is not credential evidence. Rendering
onboarding never reads credential contents or secret Keychain data.

All rolling-window reset/refill copy uses Core `ResetPhrase`: minutes below one hour, hours
below 48 hours, and days plus remaining whole hours from 48 hours, such as `6d 7h`. Zero
hours are omitted. Surfaces never introduce their own date/weekday formatter.

## 6. Settings

Settings uses a custom tab bar with Data, Appearance, Advanced, and About.
Appearance includes the visual warning and critical thresholds.
`MeterSettings` reads and writes standard defaults. Existing settings already have
standard copies, so removing App Group mirroring requires no settings migration.
Old shared defaults and widget files remain unused.

| Key | Domain value | Default |
| --- | --- | --- |
| `cardStyle` | `rings`, `bars` | `rings` |
| `progressionMode` | `left`, `used` | `left` |
| `mainMeterProvider` | `claude`, `codex` | `claude` |
| `menuBarAccount` | nearest or Claude account key | nearest |
| `codexMainMeterAccount` | nearest or Codex home id | nearest |
| `menuBarWindow` | `nearest`, `5h`, `7d`, `both` | `nearest` |
| warning threshold | percent used | 80 |
| critical threshold | percent used | 95 |
| stale interval | seconds, minimum 600 | 600 |

Startup and Appearance settings change the removed `forecast` value, or any invalid
menu-bar mode, to `nearest` in standard defaults.

Account names/plans are user overrides. Display precedence is name override then friendly
config label; plan override then account OAuth plan.
Configured paths are canonicalized and account disabling never removes the default account.

### Upgrade cleanup

`LegacyAttentionHookMigration` removes the six exact historical Claude Meter hook
commands from `hooks.Stop`, `hooks.Notification`, and `hooks.StopFailure`. It runs
off-main once at launch, including when usage polling is paused or its sources are disabled. It scans the previous config scope: `~/.claude`,
plausible immediate `~/.claude-*` directories, and configured paths. Disabled accounts
and paths with equal account keys are included.

The migration preserves user hooks, group metadata, `statusLine`, and unrelated settings.
It uses bounded settings reads and atomic writes, and writes only after removing an
exact command match. Missing files need no write. Invalid or inaccessible settings leave
`didRemoveLegacyAttentionHooks.v1` unset so a later launch can retry. The key is
set in standard defaults only after all discovered config paths have been checked.

After config cleanup succeeds, the migration makes one safe attempt to remove old files
under `~/.claude-meter/events`. It follows no directory links and can leave empty or
inaccessible directories. It preserves `sessions` and `statusline.json` and creates no
event storage or watchers.

`LegacyStatuslineMigration` runs after the attention migration at launch. It removes only
five exact known leading shell snippets: owner-only per-account, pre-umask per-account,
sanitized flat session, unsanitized flat session, and original single-file capture.
Repeated prefixes are removed. The remaining user command is preserved exactly; a
standalone capture command becomes an empty command. Other `statusLine` fields remain.

The previous installer forced `statusLine.refreshInterval` to 1 but saved no prior value.
The migration preserves the current interval because its ownership cannot be determined.
It performs no new installation, repair, or interval change. Missing files are harmless;
malformed settings stay unchanged. It checks the same config scope as hook cleanup,
including disabled accounts and paths with duplicate account keys. It writes only changed
settings and preserves settings symlinks through atomic writes to their resolved targets.

After all settings are handled, it removes captured files under `~/.claude-meter/sessions`,
`~/.claude-meter/statusline.json`, and numeric `.sl-*` temporary files. It follows no links,
checks directory and entry identity before deletion, and may leave empty directories.
Errors leave `didRemoveLegacyStatuslineBridge.v1` unset for a later launch. Only successful
settings and captured-file cleanup set that key in standard defaults. No periodic bridge
work remains. A running Claude Code process that cached its old command may need a
restart to load the changed settings.

`LegacyArtifactCleanupMigration` runs after the hook/statusline attempts and a bounded
App Group snapshot import on Claude's existing storage queue. All three existing
completion keys must be true before it removes anything. Import errors preserve the
source for retry. Migration failures are logged and do not stop application startup.
Provider restoration can request the same import on that queue; there is no second
importer that could race an accepted snapshot write.

The cleanup owns exactly these files under the user's home:

- `Library/Application Support/ClaudeMeter/cost-usage-cache.json`
- `Library/Caches/com.jewei.claudemeter/models-dev-pricing-v1.json`
- `Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter/main-meter.json`
- `Library/Application Support/ClaudeMeter/main-meter.json` (the former non-App-Group fallback)
- `Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter/current.json`
- `Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter/last-error.json`
- `Library/Application Support/ClaudeMeter/usage-history.jsonl`

Usage-history cleanup retains the old deletion behavior through this one versioned
owner. It no longer runs as a separate unversioned task. The cleanup never removes
current Application Support snapshots/errors, standard defaults, credentials, or
unknown neighboring files. Statusline and attention storage keep their existing
migration owners. The two old shared-defaults plists remain because an independently
installed older app/widget and the preferences service can still hold their values.
The current app and its bundle have no consumer of these defaults. The historical
emergency store also used generic `current.json`, `main-meter.json`, and `last-error.json`
names in the user's temporary directory. These ambiguous paths are not cleanup targets.

Cleanup traverses each path from an open home directory with no-follow directory
descriptors. It accepts only regular final files, checks directory and entry identity,
and unlinks only that entry. It never reads cache contents or recursively deletes
directories. Links, special files, and filesystem errors leave cleanup incomplete.
Independent files can still be removed on a partial failure. All seven files must be
removed or proven absent before standard defaults records `didCleanupObsoleteArtifacts.v1`.
The completed path returns after that defaults check, with no directory scan. Tests
use isolated homes/defaults; hosted tests cannot invoke live cleanup.

## 7. Networking, Keychain, and diagnostics

OAuth and other direct provider requests use `ProviderHTTPClient.shared` or an injected
`HTTPTransport`. The separate Claude reset read runs in a signed-in WebKit page, with
same-origin browser requests and WebKit-managed cookies. The direct provider session is
ephemeral and cookie-less. It has a ten-second idle timeout, an
eight-MiB response cap, and a 30-second hard deadline for the complete send, including retry
waits. A chunk receiver rejects an oversized declared `Content-Length` before body receipt
and cancels a streamed response when it crosses the cap. A dedicated timeout-task budget
bounds cancellation-ignoring work. The session refuses redirects that change HTTPS origin.
Transient retry applies only to idempotent methods and bounded, finite delays; OAuth handles
429 separately.

All Security.framework calls pass through `KeychainGateway`, which disables interaction and
fails closed in test processes unless live Keychain testing is explicitly enabled. Candidate
selection is deterministic on equal timestamps. Secret reads occur only after explicit user
action or during an enabled provider poll.

All errors are sanitized at UI and persistence boundaries. Sanitization redacts emails,
home paths, UUIDs, bearer/JWT/provider tokens, session keys, and labeled sensitive fields.

`MeterLog` is the logging seam. It sanitizes every message before the text reaches
`os.Logger` or the log file, so a call site cannot leak a secret by forgetting to sanitize.
Categories are app, poll, and oauth. The log file is opt-in through
Advanced settings, is written to `~/Library/Logs/ClaudeMeter/` at `0600`
inside a `0700` directory, rotates once at 4 MiB, and is deleted when the user turns the
setting off. Diagnostics keep showing present state only.

## 8. Verification and maintenance

The authoritative local/CI gate is:

```bash
./scripts/verify-local.sh
```

It runs strict Swift formatting checks, all Core/Provider package tests, and unsigned Debug
and Release app builds. CI invokes this script directly. Sparkle is exactly pinned by
the Xcode project and committed workspace resolution.

Release publishing must make the signed GitHub asset available before pushing the new
`appcast.xml` to `main`; users must never observe a feed pointing at a missing artifact.
Both publishing and private preparation require a clean worktree, including untracked
files. Publishing requires the source `HEAD` to equal fetched `origin/main`. The source
must remain clean at that commit before archive creation and after artifact validation.
Only then may the script change release metadata and create the release commit. Private
preparation can use another committed source. Candidate feeds stay in `build/` until
publication preparation passes these checks.
Release completion requires successful publication of the signed artifacts and feed, then
removal of the staging branch. A separate macOS account, VM, signed Sparkle upgrade test,
or upgrade report is not required for this or future releases. Local verification, signing,
notarization, matching debug symbols, DMG integrity, and feed metadata checks remain required.
Optional manual Sparkle checks do not block publication or trigger automatic feed recovery.
See `docs/releases.md`.

Tests should be hermetic: temporary directories are unique and cleaned up, wall clocks and
defaults are injectable where policy depends on them, and live user Keychain or
Application Support data is never read by default.
