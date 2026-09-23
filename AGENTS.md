# Claude Meter development rules

Report in ASD-STE100 Simplified Technical English.

## Read the relevant documents

- [SPECS.md](SPECS.md) defines behavior, settings, persistence, and system boundaries.
- [DESIGN.md](DESIGN.md) defines the UI system.
- [Issue workflow](docs/agents/issue-tracker.md) defines GitHub issue and triage conventions.
- Read the local instructions before changing code in these directories:
  [app](ClaudeMeter/AGENTS.md),
  [providers](ClaudeMeterCore/Sources/ClaudeMeterProviders/AGENTS.md).

Keep shared rules here and area-specific rules beside the code. Record behavior changes
in `SPECS.md` and visual changes in `DESIGN.md` in the same change. There is no
`CONTEXT.md` or ADR directory. Use the existing terms: account key, config dir, limit
window, energy left, OAuth, and reading state. State conflicts with
recorded decisions before changing them. Local `docs/superpowers/` notes, when present,
are ignored by Git and are not required project documentation.

## Build and test

```bash
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO
swift test --package-path ClaudeMeterCore
./scripts/verify-local.sh
```

`verify-local.sh` is the full local and CI check. Add checks there; CI must invoke the
script directly. Tests must use isolated files and settings, with no live user data.

`project.pbxproj` is maintained by hand. New target source/resource files need matching
`PBXFileReference`, `PBXBuildFile`, group, and build-phase entries with 24-character hex
IDs. Exclude instruction Markdown files from Swift package targets.

## Ownership and polling

- `AppState` is `@MainActor`. Core owns normalized models, storage, and policy, with
  Swift 6 strict concurrency and no AppKit, SwiftUI, or provider I/O. Providers owns
  HTTP and credentials; it depends only on Core. Provider tests belong
  in `ClaudeMeterProvidersTests`.
- Core's `ProviderSnapshot` owns provider-neutral account/window/balance facts. Keep
  conversion in the four provider adapters. Percentages mean used; unknown stays nil.
  All provider usage lifecycle belongs to `UsageStore`. `normalizedSnapshots` computes
  a presentation view of that owner. Never mirror
  mutable readings in AppState or add disk persistence for Cursor/Grok.
- `MeterSettings` owns app settings in standard defaults. Persist Claude snapshots in
  Application Support. The selected Claude or Codex meter owns the hero, first section,
  menu bar, and header time. Claude is the default. Missing selected data or an exact
  account pin must stay unavailable; never substitute another provider/account.
- `RefreshScheduler` owns global timing, pending requests and display sleep/wake. AppState supplies `RefreshConfiguration` explicitly and retains settings,
  selection and application coordination. The scheduler never reads UserDefaults.
  Keep optional value, timestamp,
  error, and freshness together in `ReadingState`. Providers return data only.
  `UsageStore` guards all provider publication with one token per active refresh.
  The store sequences previous reconciliation, fetch, in-memory acceptance, publication,
  then an async persistence wait. Providers return data, never publication callbacks or
  acceptance closures. MainActor acceptance may update metadata and enqueue writes, but
  must never perform blocking I/O. Keep writes ordered per provider, including accepted
  work whose caller is later canceled. Codex validates ownership
  before retaining previous accounts and again after fetching; keep these rules in Providers.
  Cancellation must preserve existing readings; disable must clear them and reject late work.
- Codex prefers direct OAuth from the configured home. Claude Meter never rotates or
  writes Codex credentials. Only credential/auth recovery may launch a bounded one-shot
  Codex App Server. Await process termination after each recovery; retain no resident child.
- Claude usage comes from OAuth, with a stale last-good snapshot on failure. Account
  assembly must exclude disabled keys, including cached accounts. One account observation
  replaces all its quota and metadata fields. Never infer an account from local activity.
- Background refresh uses one 300 s interval for all enabled providers. Popover open
  refreshes missing, failed, provider-stale or at least 60 s old readings. Manual refresh
  bypasses this age check. Authentication and shared OAuth 429 backoff stay provider-owned.
- Park the timer during display sleep. Wake checks freshness at 300 s before resuming it.
  There is no battery cadence, reachability monitor or provider-specific global cadence.
- Settings supply active state and enabled IDs. Enabling or configuring one provider
  refreshes only it, without restarting the timer. Reset countdowns update locally.
- UI age staleness defaults to 600 s, with that minimum for older stored preferences.
  This display threshold is separate from the interactive refresh threshold.

## Snapshot safety and freshness

- Never delete a legacy artifact before every migration that consumes it has completed.
  Keep cleanup retryable, use exact owned paths, and keep migration I/O off MainActor.
- `SnapshotStore` uses dedicated threads, a 2 s read limit, a 10 s write limit, and
  independent per-store circuit breakers. Reads accept regular files up to 4 MiB.
  After a timeout, fail that store immediately so polls cannot leak blocked threads.
- Validate every persisted date with `PersistedDateBounds`, Unix epoch through year
  2999. A larger finite `Date` can cause Foundation ISO-8601 encoding to trap.
  Snapshot atomic writes currently have no explicit `fsync`.
- Resolve current rolling windows with `LimitWindow.resolved(asOf:)`: an expired window
  becomes 0% used with no reset date. Stale observations from before a reset must clear
  that window to unknown.
- Advance `lastPolledAt` only on success. Derive snapshot age from
  each account's `observedAt`; selected-meter displays use `mainMeterIsStale`.
  A failed optional refresh preserves its last successful time. Provider notices keep
  their own lifecycle.
- Use Core's `ResetPhrase` for reset text. Derive countdowns from provider reset
  timestamps minus the current time.
  Never use calendar dates or per-view date formatters for rolling windows.

## Concurrency and diagnostics

- Run heavy provider and disk work off-main. Detached tasks capture only `Sendable`
  values; publish UI state on `@MainActor`.
- Async wrappers on a serial queue must call queue-local helpers. Calling `queue.sync`
  from that same queue deadlocks.
- Formatters are not `Sendable`. Create them per call, or use an immutable
  `nonisolated(unsafe) static let` only where thread safety is established.
  `ProviderDate` uses immutable shared date formatters.
- Call `DiagnosticsSanitizer.sanitize` before copying or persisting diagnostics.
  Preserve redaction of emails, home paths, UUIDs, provider tokens, JWTs, bearer values,
  `sessionKey=`, labeled access/refresh tokens, and sensitive CLI identity fields.
- Log through `MeterLog.logger(_:)`, never `NSLog`, `print`, or a direct `os.Logger`.
  The seam sanitizes for you; do not sanitize again at the call site. Log a fault, a
  policy decision, or a state change, never a per-poll success. Add the log line beside
  the existing error record; it does not replace `writeLastError` or a `SourceAttempt`.
