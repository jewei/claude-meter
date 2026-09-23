# App development rules

Follow the root [AGENTS.md](../AGENTS.md) and [DESIGN.md](../DESIGN.md).

## Presentation

- `PlayfulTheme.swift` owns colors, `PFont`, energy semantics, and 3D modifiers.
  `PlayfulComponents.swift` owns shared cards and rings.
- The default display shows energy left, `100 - percentUsed`, with depleting fills.
  `progressionMode` switches all provider numbers and fills between left and used.
  Severity always takes percent used, with default warning 80 and critical 95.
- Bundle static Fredoka/Nunito faces through the Fonts folder reference and
  `ATSApplicationFontsPath = Fonts`. `PFont` maps weights to PostScript names.
  Keep system fonts in the menu bar for its metrics.
  Regenerate all 10 AppIcon sizes when changing the SwiftUI-drawn bolt icon.
- Account names and plans in `MeterSettings` are user overrides. Name precedence is
  override then `friendlyName(label)`. Plan precedence is override then account OAuth plan.
- `mainMeterSeverity` and `mainMeterLimitSets` use the selected provider's exact account
  pin, or its nearest-limit account policy. The menu-bar dot uses severity across all
  considered windows, even when the text shows only one window.
- Settings uses Data, Appearance, Advanced, and About tabs and `SettingsWindowAccessor`
  for the title. Visual severity thresholds belong in Appearance.
- `PopoverView` owns disclosure state, persistence, and rendering. `PopoverTransitionBody`
  owns measurement, resizing, clipping, interruption, and Reduce Motion. When Codex is
  primary, Claude expands inside one secondary card to show all its accounts and limits.
- Keep account management in Settings; the popover has no duplicate footer action.

The accessibility summary beside `MenuBarText` must distinguish the spoken window from
severity across all windows. Hide child labels to prevent duplicate announcements.
Omit stale or paused percentages. `MenuBarAccessibility` sets the native status-button
summary. Keep the public AX title override until a native
proxy check confirms it is unnecessary; SwiftUI labels and AppKit titles can leave that
proxy reading only compact text.

## Provider lifecycle ownership

`UsageStore` owns all four providers' normalized readings, loading, cancellation and
stale-last-good behavior. AppState must not hold another mutable usage reading.
RefreshScheduler owns global timing/admission. AppState supplies configuration and forwards
store change notifications without copying state. All provider presentation consumes Core models; it must not inspect provider wire types.

Fetches run off-main. Cursor/Grok use the store timeout. Claude and Codex own their
bounded fetch deadlines. Claude account timing, diagnostics and persistence stay in Providers.
The store calls `validatePrevious`, publishes changed valid previous accounts, calls `fetch`,
then accepts through `didAccept` and publishes without suspension after its token check.
Acceptance only updates memory and queues provider-owned I/O. Clear loading before
awaiting `waitForPersistence`; no disk work may block MainActor. Check refresh ownership
after fetch/reconciliation suspensions. Once accepted, writes survive cancellation and
later refreshes. Providers return data without calling publication code. A newer request
supersedes only that provider. Provider adapters classify and sanitize failures. Cursor credential
rejection clears last-good data; temporary failures retain it. Outer stale state applies to
all retained accounts without rewriting their source observation or its timestamp.

## Refresh scheduling and display sleep

- `RefreshScheduler` owns one 300 s timer and merges queued provider requests. UsageStore's
  refreshing set suppresses duplicate automatic work; explicit refresh may supersede it.
- Configuration contains only active state and enabled provider IDs. AppState combines
  onboarding with pause state. Scheduler forwards enable/disable to UsageStore.
- Start/resume refreshes enabled providers. Enabling a provider or changing its configuration
  refreshes only that provider without resetting the timer. Main-meter selection has no
  scheduling effect. The scheduler does not read UserDefaults.
- Popover open uses Core's reading freshness helper with a 60 s threshold. Manual refresh
  bypasses age checks. The visible popover's one-second timer only updates local countdowns.
- PowerMonitor tracks display sleep and wake. Park on `screensDidSleep`, not `willSleep`,
  because system sleep can be cancelled. Wake checks freshness at 300 s and resumes the
  timer. Stop/sleep cancel queued work and active store work.
  Do not add a battery cadence, reachability monitor or periodic asleep check.
- Keep observer tokens in the nonisolated `ObserverBag` for Swift 6 deinit cleanup.
  Scheduler tests inject time, sleep and display state. Use gates, not real poll delays.
- `AppState.init(usageStore:)` skips system monitors and gives `setActive` an isolated
  defaults suite. Tests must not write shared pause settings. Aggregate loading comes
  only from UsageStore; do not mirror it.
