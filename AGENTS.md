# Claude Meter development rules

Report in ASD-STE100 Simplified Technical English.

## Documents

- [SPECS.md](SPECS.md) defines behavior, settings, persistence, and system boundaries.
  It is also the glossary and decision record. There is no `CONTEXT.md` or ADR directory.
- [DESIGN.md](DESIGN.md) defines the UI system.
- [docs/releases.md](docs/releases.md) defines release and artifact checks.
- [Issue workflow](docs/agents/issue-tracker.md) defines GitHub issue and triage conventions.
- Before you change code in these directories, read their rules:
  [app](ClaudeMeter/AGENTS.md), [providers](ClaudeMeterCore/Sources/ClaudeMeterProviders/AGENTS.md).

Record behavior changes in `SPECS.md` and visual changes in `DESIGN.md` in the same
change. Keep shared rules here and area rules beside the code. Use the existing terms:
account key, config dir, limit window, energy left, OAuth, and reading state. State a
conflict with a recorded decision before you change it.

Prefer deleting a requirement to adding an abstraction. Four known providers need no
plugin framework or speculative flexibility.

## Build and test

```bash
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO
swift test --package-path ClaudeMeterCore
./scripts/verify-local.sh
```

`verify-local.sh` is the full local and CI gate. Add checks there; CI invokes the script
directly. Tests use isolated files, defaults, and clocks, with no live user data.

`project.pbxproj` is maintained by hand. A new target source or resource file needs
matching `PBXFileReference`, `PBXBuildFile`, group, and build-phase entries with
24-character hex IDs. Exclude instruction Markdown files from Swift package targets.

## Ownership

- The app owns presentation, settings, and scheduling; `AppState` is `@MainActor`. Core
  owns normalized models, storage, and policy, with Swift 6 strict concurrency and no
  AppKit, SwiftUI, or provider I/O. Providers owns HTTP, credentials, and the four
  adapters, and depends only on Core. Provider tests go in `ClaudeMeterProvidersTests`.
- `UsageStore` is the single owner of provider readings. `ReadingState` keeps value,
  timestamp, error, and freshness together. `AppState.normalizedSnapshots` is a
  computed view. AppState holds no copy of a reading; Cursor and Grok have no disk
  persistence.
- Providers return data only, never publication callbacks or acceptance closures.
  MainActor acceptance updates memory and enqueues writes, with no blocking I/O. Accepted
  writes stay ordered per provider and survive caller cancellation. Cancellation keeps
  existing readings; disable clears them and rejects late work.
- `MeterSettings` owns app settings in standard defaults. The selected Claude or Codex
  meter owns the hero, first section, menu bar, and header time. Missing selected data
  or a missing pinned account stays unavailable; show no other provider or account.
- `RefreshScheduler` owns timing, pending requests, and display sleep/wake. It receives
  `RefreshConfiguration` from AppState and never reads UserDefaults. The refresh policy is
  in SPECS.md; keep one global cadence, with no battery, reachability, or per-provider timer.
- Claude Meter writes only its own manual Claude OAuth credentials. Claude Code, Codex,
  and Cursor own their credential rotation and storage. Identify an account from its
  credentials and config, never from local activity.

## Persistence and time

- Keep a legacy artifact until every migration that consumes it completes. Cleanup is
  retryable, uses exact owned paths, and runs off MainActor.
- `SnapshotStore` uses dedicated threads, time limits, and a circuit breaker per store.
  After a timeout, fail that store at once so polls cannot leak blocked threads.
- Validate every persisted date with `PersistedDateBounds`. A larger finite `Date` can
  make Foundation ISO-8601 encoding trap.
- Resolve rolling windows with `resolved(asOf:isStale:)` before display or policy. An
  expired current window is 0% used with no reset; an expired stale window is unknown.
- Advance `lastPolledAt` only on success. Snapshot age comes from each account's
  `observedAt`; selected-meter displays use `mainMeterIsStale`.
- Format reset text with Core's `ResetPhrase`, from the provider reset time minus now.
  Rolling windows use no calendar dates or per-view date formatters.

## Concurrency and diagnostics

- Run heavy provider and disk work off-main. Detached tasks capture only `Sendable`
  values; publish UI state on `@MainActor`.
- An async wrapper on a serial queue calls queue-local helpers. `queue.sync` from that
  same queue deadlocks.
- Formatters are not `Sendable`. Create them per call, or use an immutable
  `nonisolated(unsafe) static let` where thread safety is established, as `ProviderDate` does.
- Call `DiagnosticsSanitizer.sanitize` before you copy or persist diagnostics. Keep
  redaction of emails, home paths, UUIDs, provider tokens, JWTs, bearer values,
  `sessionKey=`, labeled access/refresh tokens, and sensitive CLI identity fields.
- Log only through `MeterLog.logger(_:)`; it sanitizes, so call sites pass raw text.
  Log a fault, a policy decision, or a state change, not a per-poll success. Put the log
  line beside the existing `writeLastError` or `SourceAttempt` record, not in its place.
