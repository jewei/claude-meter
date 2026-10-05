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
RefreshScheduler ──refresh(quota:history:)──▶ UsageStore ──reconcile, fetch───▶ UsageProvider
                 ──reconcile(_:)────────────▶     │      ──reconcile, history─▶ TokenHistoryProvider
                                                  │            (Claude, Codex, Cursor, Grok)
                                                  │ readings: [ProviderID: Reading<ProviderUsage>]
                                                  │ histories: [ProviderID: Reading<ProviderTokenHistory>]
                                                  ▼
                                     Presentation builders (pure, given Settings and now)
                                                  ▼
                                        MenuBarModel, PopoverModel ──▶ MeterUI views
```

The scheduler calls `UsageStore.refresh(quota:history:)` when requests may go out, and
`UsageStore.reconcile(_:)` (local reads only) when they may not.

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
5. On `ProviderError` or the safety deadline, when `keepsLastReading` is true (always for
   the deadline): keep an observed previous value as `.stale`, and the accounts of a failed
   reading as `.failed(issue, partial:)`, so a first 429 hold reaches the next fetch.
   Otherwise `.failed(issue)`. Cancellation changes nothing.
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

## Rate limits: one hold for Codex, Cursor, and Grok

After HTTP 429 with a usable `Retry-After`, a provider sends no request for the same login
before the retry time, so the card's countdown is true. One pure rule decides
(`RateLimitHold`):

- The retry time is the server's, at most 1 hour after the 429.
- The hold stops only the requests of the login (`AccountOwner`) that got the 429, in every
  account of that login (Codex homes). Another login sends at once.
- A retry time more than 1 hour after now holds nothing. The rule never makes one, so the
  clock moved back or an older version saved it in the reading archive. That hold ends.
- A 429 without a usable `Retry-After` holds nothing.

Quota keeps the hold in the account's issue (`AccountUsage.rateLimitHold(for:now:)`): the
refresh keeps the account as stale with that issue and sends nothing. A refresh that sends
nothing for another reason (an expired token, a login that cannot be read now, or a Codex home
that did not finish in time) keeps the hold's issue, not its own, while the login can still be
the same (`AccountUsage.rateLimitHold(admittedBy:now:)`). A sign-out or another login ends the
hold for that account.

A hold survives a restart only when the reading archive saves its account: an account with an
observation and an identity owner (`ProviderUsage.persistable`, see Storage). A loaded hold
still ends within 1 hour. The hold after a 429 on an account without an observation (a first
429), and after a 429 for a login known only by its credential, ends at a restart. The hold of
Cursor token history lives only in memory, so a restart ends it.

A provider keeps in memory the holds that no account issue carries: the hold after a 429 on
the Cursor plan request, and the holds after a 429 on the Codex reset-credit details request.
The usage request of that refresh succeeded, so the account has no issue. A restart before the
next refresh ends such a hold. A refresh during the hold puts the 429 issue on the account, and
that hold then survives a restart like a usage-request hold.

Claude has its own gate, because one Claude limit covers every account and the Settings check
(`docs/providers/claude-oauth.md`).

## Scheduling (`RefreshScheduler`)

| Event | Refreshes quota of |
| --- | --- |
| Start or resume | Every enabled provider |
| Every 300 s while the display is awake | Every enabled provider not already refreshing |
| Popover opens | Readings that are missing, failed, stale, or at least 60 s old |
| Display wakes | Readings that are missing, failed, stale, or at least 300 s old; then the timer restarts |
| A provider is enabled, or its accounts or credentials change | That provider only |
| Display sleeps, pause, quit | Nothing; cancels the timer and in-flight work |

Token history has its own due rule (`UsageStore.historyNeedsRefresh`): a history is due when
it was never read, when the local day or time zone changed since its last attempt, or when
that attempt is at least 240 s old (a failed history waits too). The timer, an opened
popover, and a display wake check it for every enabled provider. A start, a resume, or an
enabled provider checks it only for the providers that start. A due history never adds a
quota request, and a quota request never adds a history that is not due. An account or
credential change refreshes that provider's history at once, due or not.

When no request may go out (paused, before onboarding, or with the display asleep), an
account or credential change still runs that provider's `reconcile` alone
(`UsageStore.reconcile`): local reads, no request, and the result is published and saved. So
a removed account or a changed login disappears at once. At launch, saved readings are
reconciled the same way when no request may go out, also with the display asleep.

A saved reading holds only identity-owned accounts (see Storage), so it can lack an account
that is still configured. `UsageStore.restored` marks it until the first publish or failure,
or a reconcile that removes it; a reconcile that keeps a value only drops saved accounts, so
the mark stays. While it is marked, a pin that it lacks is not missing (`MainMeter`).

There is one global cadence. No battery, network, or per-provider timers.

## Storage

| Data | Where | Format |
| --- | --- | --- |
| Settings | `UserDefaults` key `settings`; memory only in a test process | JSON of `Settings` |
| Last readings | `~/Library/Application Support/ClaudeMeter/readings.json` | JSON of `[ProviderID: ProviderUsage]`, identity owners only; an entry that does not load is skipped |
| Claude rate-limit deadline | `UserDefaults` key `claude.rateLimitedUntil`; memory only in a test process | JSON `{recordedAt, until}` |
| Manual Claude OAuth | Keychain, service `com.jewei.claudemeter.claude-oauth`, account `manual` | JSON `{accessToken, refreshToken, expiresAt, connectionID}` |
| Log file (opt-in) | `~/Library/Logs/ClaudeMeter/ClaudeMeter.log`; a temporary folder in a test process | text, 0600, rotates once at 4 MiB |

Every JSON value above stores dates as ISO-8601 text (`JSONEncoder.meter`): a whole second
as `2026-10-04T12:00:00Z`, and a date with a fraction with milliseconds, as
`2026-10-04T12:00:00.750Z`. Both forms load. Token history is memory only and rebuilt after
launch.

The app itself writes nothing else. `Log` also sends each entry to the system log
(subsystem `com.jewei.claudemeter`). Frameworks keep their own state in the app's
`UserDefaults`: AppKit saves the Settings window frame (key
`NSWindow Frame ClaudeMeterSettings`, from `SettingsWindowController.frameName`), and Sparkle
keeps its update state in keys that start with `SU`. Launch at login is registered with
`SMAppService`, and the system keeps that record.

## Time limits

| Work | Limit |
| --- | --- |
| One HTTP send, including retries | 30 s (provider requests may set less) |
| One provider refresh (safety net) | 90 s |
| One history refresh | 20 s |
| Blocking file, SQLite, or Keychain read | 5 s; 3 s for a Codex `auth.json`, 2 s for the Cursor credentials of a history read. A read past its limit is abandoned and keeps its thread until it ends; while 16 abandoned reads still run, new reads fail at once. History scans have a separate pool (`BlockingIO.history`) with the same limits, but a scan that finds it full first waits up to 2 s (`HistoryLimits.busyRetries` tries, 50 ms apart) for a stuck read to end. |
| Child process (Codex recovery) | 5 s for the search and `initialize`, 10 s each for `account/read` and `account/rateLimits/read`; TERM, then KILL after 0.25 s, then at most 2 s for the reap |
