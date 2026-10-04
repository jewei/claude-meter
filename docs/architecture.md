# Architecture

How data moves from a provider to the menu bar, and which type owns each decision.

## Layers

```text
MeterDomain     values and pure rules          (no I/O)
MeterPlatform   OS adapters                    (HTTP, Keychain, files, SQLite, processes, logs)
Provider*       one module per provider        (credentials, wire formats, mapping)
MeterApp        settings, refresh, storage,    (MainActor state, pure presentation builders)
                presentation models
MeterUI         SwiftUI views, status item,    (renders presentation models)
                popover panel, Settings window
App/            entry point and Sparkle        (no logic)
```

A module imports only the layers above it. Providers never import each other.

## Data flow

```text
RefreshScheduler ──refresh(ids)──▶ UsageStore ──reconcile/fetch──▶ UsageProvider
                                       │                              (Claude, Codex, Cursor, Grok)
                                       │ readings: [ProviderID: Reading<ProviderUsage>]
                                       │ histories: [ProviderID: Reading<ProviderTokenHistory>]
                                       ▼
                          Presentation builders (pure, given Settings and now)
                                       ▼
                             MenuBarModel, PopoverModel ──▶ MeterUI views
```

`UsageStore` is the only owner of readings. Presentation builders derive everything else on
each render from the readings, the settings, and the current time. Nothing caches a derived
copy.

## The provider contract

```swift
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func reconcile(_ previous: ProviderUsage?) async -> ProviderUsage?
    func fetch(previous: ProviderUsage?) async throws -> ProviderUsage
}
```

- `reconcile` uses local reads only. It removes accounts that left the configuration and
  observations whose owner changed (see retention). The store publishes a changed result
  before the fetch, so a changed login disappears at once.
- `fetch` returns every configured account. A failed account is either kept as stale with
  its issue (`AccountUsage.retained(issue:now:)`) or listed as unavailable
  (`AccountUsage.unavailable`). It throws `ProviderError` only when the provider as a whole
  failed.
- Each provider bounds its own work. The store adds a 90 s safety deadline over reconcile and
  fetch together. It ends the refresh even when the provider ignores cancellation, so the
  provider is free for the next refresh, and it drops the late result.

`TokenHistoryProvider` is separate and independent: history never changes quota freshness,
selection, severity, or the menu bar.

## Refresh lifecycle (`UsageStore`)

Each provider has at most one refresh in flight, identified by a token.

1. A new refresh cancels the previous one for the same provider only.
2. `reconcile(previous)`. If the result differs, publish it and save it to the reading
   archive at once (nil removes the reading; a failed reading keeps its issue), so a removed
   login never returns at the next launch even when the fetch is cancelled.
3. `fetch(previous: reconciled)` under the safety deadline.
4. If the token is still current and the provider is still enabled, publish:
   - any account has an observation → `.current(usage, observedAt: usage.observedAt)`;
   - none → `.failed(firstIssue, partial: usage)`.
5. On `ProviderError` or the safety deadline: keep the previous value as `.stale` when
   `keepsLastReading` is true (always for the deadline) and a value exists; otherwise
   `.failed`. Cancellation changes nothing.
6. Save the published value to the reading archive (newest value wins, written off-main).

Disabling a provider cancels its refresh, removes its readings, and rejects late results.
History refreshes follow the same pattern with their own tokens and a 20 s deadline.

## Retention: one rule for every provider

A reading may outlive a failed refresh only while it belongs to the signed-in login.

- Providers compute an `AccountOwner` for each observation from local credentials:
  `.identity(sha256)` from stable account IDs when the credentials name them, otherwise
  `.credential(sha256)` from the credential itself.
- Before and after each request a provider reads the current `OwnerStatus`:
  `.signedIn(owner)`, `.signedOut`, or `.unknown` (temporary read failure).
- `AccountUsage.belongs(to:)` decides: same owner or unknown → keep; signed out or a
  different owner → drop. A response that arrives after the login changed is discarded.

Token history follows the same lifecycle and rule. The store runs
`TokenHistoryProvider.reconcile` and then `history(now:previous:)` with the reconciled value,
both inside the 20 s history limit, and publishes a changed reconcile result at once. An
account history (Cursor's export) carries the owner of its login
(`ProviderTokenHistory.owner`), and `ProviderTokenHistory.belongs(to:)` applies the same
`OwnerStatus.admits(_:)` rule, so a failure keeps it, marked stale, only while its owner is
signed in or the login cannot be read. Local history (`.thisMac`) belongs to its folders, not
to a login, so it always belongs.

## Rate limits: one hold for Cursor and Grok

After HTTP 429 with `Retry-After`, a provider sends no request for the same login before the
retry time, so the card's countdown is true. One pure rule decides (`RateLimitHold`):

- The retry time is the server's, at most 1 hour after the 429.
- The hold stops only the requests of the login (`AccountOwner`) that got the 429. Another
  login sends at once.
- A retry time more than 1 hour after now holds nothing. The rule never makes one, so the
  clock moved back or an older version saved it in the reading archive. That hold ends.
- A 429 without a usable `Retry-After` holds nothing.

Quota keeps the hold in the account's issue (`AccountUsage.rateLimitHold(for:now:)`): the
refresh keeps the account as stale with that issue and sends nothing. The hold survives a
restart in the reading archive and still ends within 1 hour. Cursor token history keeps the
hold of its last 429 in memory. Claude has its own gate, because one Claude limit covers every
account and the Settings check (`docs/providers/claude-oauth.md`).

## Scheduling (`RefreshScheduler`)

| Event | Refreshes quota of |
| --- | --- |
| Start or resume | Every enabled provider |
| Every 300 s while the display is awake | Every enabled provider not already refreshing |
| Popover opens | Readings that are missing, failed, stale, or at least 60 s old |
| Display wakes | Readings at least 300 s old; then the timer restarts |
| A provider is enabled, or its accounts or credentials change | That provider only |
| Display sleeps, pause, quit | Nothing; cancels the timer and in-flight work |

Token history has its own due rule, checked at each of these events for every enabled
provider: a history is due when it was never read, when the local day or time zone changed
since its last attempt, or when that attempt is at least 240 s old (a failed history waits
too). A due history never adds a quota request, and a quota request never adds a history
that is not due. An account or credential change refreshes that provider's history at once.

When no request may go out (paused, before onboarding, or with the display asleep), an
account or credential change still runs that provider's `reconcile` alone
(`UsageStore.reconcile`): local reads, no request, and the result is published and saved. So
a removed account or a changed login disappears at once. At launch, saved readings are
reconciled the same way when no request may go out, also with the display asleep.

There is one global cadence. No battery, network, or per-provider timers.

## Storage

| Data | Where | Format |
| --- | --- | --- |
| Settings | `UserDefaults` key `settings` | JSON of `Settings` |
| Last readings | `~/Library/Application Support/ClaudeMeter/readings.json` | JSON of `[ProviderID: ProviderUsage]`, identity owners only; an entry that does not load is skipped |
| Claude rate-limit deadline | `UserDefaults` key `claude.rateLimitedUntil` | JSON `{recordedAt, until}` |
| Manual Claude OAuth | Keychain, service `com.jewei.claudemeter.claude-oauth`, account `manual` | JSON `{accessToken, refreshToken, expiresAt, subscriptionType, connectionID}` |
| Log file (opt-in) | `~/Library/Logs/ClaudeMeter/ClaudeMeter.log`; a temporary folder in a test process | text, 0600, rotates once at 4 MiB |

Every JSON value above stores dates as ISO-8601 text (`JSONEncoder.meter`): a whole second
as `2026-10-04T12:00:00Z`, and a date with a fraction with milliseconds, as
`2026-10-04T12:00:00.750Z`. Both forms load. Token history is memory only and rebuilt after launch. Nothing
else is written.

## Time limits

| Work | Limit |
| --- | --- |
| One HTTP send, including retries | 30 s (provider requests may set less) |
| One provider refresh (safety net) | 90 s |
| One history refresh | 20 s |
| Blocking file, SQLite, or Keychain read | 5 s. A read past its limit is abandoned and keeps its thread until it ends; while 16 abandoned reads still run, new reads fail at once. History scans have a separate pool with the same limits. |
| Child process (Codex recovery) | 5 s for the search and `initialize`, 15 s each for `account/read` and `account/rateLimits/read`; TERM, then KILL after 0.25 s |
