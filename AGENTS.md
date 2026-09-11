# Claude Meter development rules

Report in ASD-STE100 Simplified Technical English.

## Read the relevant documents

- [SPECS.md](SPECS.md) defines behavior, settings, persistence, and system boundaries.
- [DESIGN.md](DESIGN.md) defines the UI system.
- [Issue workflow](docs/agents/issue-tracker.md) defines GitHub issue and triage conventions.
- Read the local instructions before changing code in these directories:
  [app](ClaudeMeter/AGENTS.md),
  [providers](ClaudeMeterCore/Sources/ClaudeMeterProviders/AGENTS.md),
  [widget](ClaudeMeterWidget/AGENTS.md).

Keep shared rules here and area-specific rules beside the code. Record behavior changes
in `SPECS.md` and visual changes in `DESIGN.md` in the same change. There is no
`CONTEXT.md` or ADR directory. Use the existing terms: account key, config dir, limit
window, energy left, statusline bridge, tier, and reading state. State conflicts with
recorded decisions before changing them. Local `docs/superpowers/` notes, when present,
are ignored by Git and are not required project documentation.

## Build and test

```bash
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO
swift test --package-path ClaudeMeterCore
./scripts/verify-local.sh
```

Unsigned builds can compile. Running the app requires an App Group provisioning profile.
`verify-local.sh` is the full local and CI check. Add checks there; CI must invoke the
script directly. Tests must use isolated files and settings, with no live user data.

`project.pbxproj` is maintained by hand. New target source/resource files need matching
`PBXFileReference`, `PBXBuildFile`, group, and build-phase entries with 24-character hex
IDs. Exclude instruction Markdown files from Swift package targets.

## Ownership and polling

- `AppState` is `@MainActor`. Core owns normalized models, storage, and policy, with
  Swift 6 strict concurrency and no AppKit, SwiftUI, or provider I/O. Providers owns
  HTTP, credentials, bridges, and scans; it depends only on Core. Provider tests belong
  in `ClaudeMeterProvidersTests`.
- `AppGroupConfig` owns `group.com.jewei.claudemeter` and shared display settings.
  Persist `MainMeterReading`, never UI models or provider wire types. The selected
  Claude or Codex meter owns the hero, first section, menu bar, header time, widget,
  and quota alerts. Claude is the migration default. Missing selected data or an exact
  account pin must stay unavailable; never substitute another provider/account.
- Capture one immutable `PollConfiguration` per cycle. Keep optional value, timestamp,
  error, and freshness together in `ReadingState`. Source pipelines return data only.
  `AppState` commits snapshots after assembly and a final generation check. A canceled
  old poll must not overwrite a newer result.
- Build enabled Claude tiers in this order: `StatuslinePipeline`, `OAuthPipeline`,
  `CachedSnapshotPipeline`. Wrap the chain in `DisabledClaudeAccountFilteringPipeline`
  so fallback cannot restore disabled accounts.
- `SecondaryPollPolicy` may slow only popover-only sources. Never gate Claude, whose first
  tier is a local file read, and never gate the selected main provider, which owns alerts
  and the menu bar. `AppState.isRateLimitable` states the rule; keep it pure and tested.
  Its idle interval must stay one cycle below the configured stale interval, or the policy
  would itself make a card stale. An open popover, wake, and reconnect admit every source.
- Poll cadence and statusline max age are 60 s. Keep `StatuslinePipeline.fallbackCooldown`
  at 120 s, above cadence and below the 180 s default stale threshold. Cooldown results
  retain their observation time. Interactive refresh bypasses and records this cooldown;
  it never bypasses the shared OAuth 429 gate or other correctness rules. See
  `StatuslineFallbackCooldownTests`.
- `scheduleRebuildPipeline()` debounces for 300 ms without restarting the poll loop.
  Bridge/hook reconciliation allows one active task and one pending rerun. Do not chain
  cancel-and-await operations around filesystem work that can ignore cancellation.
- Anthropic status runs as a coalesced unstructured advisory task. Do not join it to
  quota fetching with `async let` or a task group. Cost scans also run separately from
  quota publication; see the app instructions.

## Snapshot safety and freshness

- `SnapshotStore` uses dedicated threads, a 2 s read limit, a 10 s write limit, and
  independent per-store circuit breakers. Reads accept regular files up to 4 MiB.
  After a timeout, fail that store immediately so polls cannot leak blocked threads.
  Even `open(2)` can block on the App Group filesystem.
- Validate every persisted date with `PersistedDateBounds`, Unix epoch through year
  2999. A larger finite `Date` can cause Foundation ISO-8601 encoding to trap.
  Snapshot atomic writes currently have no explicit `fsync`.
- File mtime is not usage freshness. An idle statusline can rewrite old data each second.
  Resolve current rolling windows with `LimitWindow.resolved(asOf:)`: an expired window
  becomes 0% used with no reset date. Stale observations from before a reset must clear
  that window to unknown. Keep the raw statusline reset internally so same-account OAuth
  data fetched after it can replace the inferred zero.
- Advance `lastPolledAt` only on success. Derive snapshot age from
  `lastSuccessfulPollAt`; selected-meter displays and alerts use `mainMeterIsStale`.
  A failed optional refresh preserves its last successful time and is not a new alert
  observation. Provider notices keep their own lifecycle.
- Use Core's `ResetPhrase` for all reset text: `compact` in widgets and `spoken` in
  prose. Never use calendar dates or per-view date formatters for rolling windows.
- Calculate pace on resolved windows using `LimitWindowKind`, 5 h session or 7 d weekly.
  Invalid reset spans give unknown pace. Use `RunsOutPhrase` for predicted depletion.
  Pace and forecasts affect copy only, never severity or tint. A menu-bar forecast must
  describe the same binding window as its percentage, or show the percentage alone.

## Concurrency and diagnostics

- Run heavy provider and disk work off-main. Detached tasks capture only `Sendable`
  values; publish UI state on `@MainActor`.
- Async wrappers on a serial queue must call queue-local helpers. Calling `queue.sync`
  from that same queue deadlocks.
- Formatters are not `Sendable`. Create them per call, or use an immutable
  `nonisolated(unsafe) static let` only where thread safety is established. Follow
  `JournalReader` for cached date formatters; never allocate a formatter per journal line.
- Call `DiagnosticsSanitizer.sanitize` before copying or persisting diagnostics.
  Preserve redaction of emails, home paths, UUIDs, provider tokens, JWTs, bearer values,
  `sessionKey=`, labeled access/refresh tokens, and sensitive CLI identity fields.
- Log through `MeterLog.logger(_:)`, never `NSLog`, `print`, or a direct `os.Logger`.
  The seam sanitizes for you; do not sanitize again at the call site. Log a fault, a
  policy decision, or a state change, never a per-poll success. Add the log line beside
  the existing error record; it does not replace `writeLastError` or a `SourceAttempt`.
