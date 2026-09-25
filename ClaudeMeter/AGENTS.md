# App development rules

Visual rules are in [DESIGN.md](../DESIGN.md).

## Presentation

- `PlayfulTheme.swift` owns colors, `PFont`, energy semantics, and 3D modifiers.
  `PlayfulComponents.swift` owns shared cards and rings.
- Presentation reads Core models only, never provider wire types.
- Numbers and fills show energy left, `100 - percentUsed`, unless `progressionMode` is
  `used`. Severity always takes percent used.
- Fredoka and Nunito ship as static faces in the Fonts folder reference, registered by
  `ATSApplicationFontsPath = Fonts`. `PFont` maps weights to PostScript names. The menu
  bar keeps system fonts for their metrics. When you change the SwiftUI-drawn bolt icon,
  regenerate all 10 AppIcon sizes.
- Account name precedence is the `MeterSettings` override, then `friendlyName(label)`.
  Plan precedence is the override, then the account OAuth plan.
- `mainMeterSeverity` and `mainMeterLimitSets` use the selected provider's exact account
  pin, or its nearest-limit account.
- `PopoverView` owns disclosure state, persistence, and rendering. `PopoverTransitionBody`
  owns measurement, resizing, clipping, interruption, and Reduce Motion.
- Settings uses `SettingsWindowAccessor` for the window title. Account management stays
  in Settings.

## Menu-bar accessibility

The summary beside `MenuBarText` names the spoken window and, separately, the severity
across all windows. Hide child labels to prevent duplicate announcements. Stale and
paused summaries omit the percentage. `MenuBarAccessibility` sets the native status-button
summary. Keep the public AX title override until a native proxy check shows it is not
necessary: SwiftUI labels and AppKit titles can leave that proxy with only compact text.

## Refresh lifecycle

`UsageStore` runs each provider refresh in this order: `validatePrevious`, publish changed
previous accounts, `fetch`, token check, `didAccept`, publish without suspension, clear
loading, then await `waitForPersistence`. Check refresh ownership after each suspension.
A newer request supersedes only its own provider. Cursor and Grok use the store timeout;
Claude and Codex own their deadlines. Loading state also comes only from UsageStore.

Outer stale state applies to all retained accounts. It does not rewrite an account's
observation or timestamp.

## Scheduling and display sleep

- `RefreshScheduler` merges queued provider requests. UsageStore's refreshing set
  suppresses duplicate automatic work; explicit refresh can supersede it.
- AppState combines onboarding with pause state into `RefreshConfiguration`. Main-meter
  selection has no scheduling effect.
- The visible popover's one-second timer updates only local countdowns.
- `PowerMonitor` parks on `screensDidSleep`, not `willSleep`, because system sleep can be
  cancelled. Stop and sleep cancel queued work and active store work.
- Keep observer tokens in the nonisolated `ObserverBag` for Swift 6 deinit cleanup.

## Tests

- Scheduler tests inject time, sleep, and display state. Use gates, not real poll delays.
- `AppState.init(usageStore:)` skips system monitors and gives `setActive` an isolated
  defaults suite, so tests never write shared pause settings.
