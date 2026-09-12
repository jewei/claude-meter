# App development rules

Follow the root [AGENTS.md](../AGENTS.md) and [DESIGN.md](../DESIGN.md).

## Presentation

- `PlayfulTheme.swift` owns colors, `PFont`, energy semantics, and 3D modifiers.
  `PlayfulComponents.swift` owns shared cards, rings, and the activity grid.
- The default display shows energy left, `100 - percentUsed`, with depleting fills.
  `progressionMode` switches all provider numbers and fills between left and used.
  Severity always takes percent used, with default warning 80 and critical 95.
- Bundle static Fredoka/Nunito faces through the Fonts folder reference in both targets.
  Each target needs `ATSApplicationFontsPath = Fonts`. `PFont` and widget `WFont` map
  weights to exact PostScript names. Keep system fonts in the menu bar for its metrics.
  Regenerate all 10 AppIcon sizes when changing the SwiftUI-drawn bolt icon.
- Account names and plans in `AppGroupConfig` are user overrides. Name precedence is
  override then `friendlyName(label)`. Plan precedence is override, active-account
  OAuth plan, then per-account OAuth plan.
- `mainMeterSeverity` and `mainMeterLimitSets` use the selected provider's exact account
  pin, or its nearest-limit account policy. The menu-bar dot uses severity across all
  considered windows, even when the text shows only one window.
- Appearance settings sync through the App Group. Provider/account/progression changes
  republish or reload the widget. `selectionRevision` must invalidate old publications
  after a failed switch or clear. Card style affects the popover; the widget keeps rings.
  Settings uses its custom tab bar and `SettingsWindowAccessor` for the title.
- `PopoverView` owns disclosure state, persistence, and rendering. `PopoverTransitionBody`
  owns measurement, resizing, clipping, interruption, and Reduce Motion. When Codex is
  primary, Claude expands inside one secondary card to show all its accounts and limits.
- `UsageSpendView` is a `Window` scene, opened from the Activity screen through
  `openWindow(id: AppState.usageSpendWindowID)`. It loads through
  `loadSpendBreakdown(daysBack:)`, which is separate from `costReading` because the poll
  covers seven days only. Keep presentation rules in `SpendBreakdownFormat` so they stay
  testable: a missing day is absent, never a zero bar, and the export carries no paths.
  A new window must join the `isSettingsWindowVisible` check in `AppUpdater`, or an
  `LSUIElement` app drops to `.accessory` and strands it without Cmd-Tab.
- The cost card opens `ActivityHeatmapGrid` with a Back button through
  `loadActivityHeatmap`. Load it off-main on demand, never in the quota pipeline.
  Keep account management in Settings; the popover has no duplicate footer action.

The accessibility summary beside `MenuBarText` must distinguish the spoken window from
severity across all windows. Hide child labels to prevent duplicate announcements. Use
`RunsOutPhrase.spoken` and omit stale or paused percentages. `MenuBarAccessibility`
sets the native status-button summary. Keep the public AX title override until a native
proxy check confirms it is unnecessary; SwiftUI labels and AppKit titles can leave that
proxy reading only compact text.

## Poll work and system monitors

- Cost scans run outside the quota task group. Allow one active scan and the latest
  pending configuration, with a separate one-worker timeout budget. Merge completion
  only into the current snapshot under its captured generation and source settings.
  Never change quota timestamps, clear provider errors, or send quota alerts.
- The cost card uses its own dated `ReadingState`. A new scan must verify persisted
  totals' root scope before display. Preserve old totals after an empty partial scan
  only when the verified roots and configuration match. A timeout has no verified
  scope and clears old totals; a complete empty scan also clears them. Account changes
  invalidate old cost results immediately, including during the rebuild debounce.
- `PowerMonitor` stays in the app target. Park polling on `screensDidSleep`, not
  `willSleep`, because sleep can be canceled. Recheck every 300 s while asleep, refresh
  immediately on wake, and multiply the 60 s poll interval by two on battery.
  Keep observer tokens in the nonisolated `ObserverBag` for Swift 6 deinit cleanup.
- `NetworkMonitor` refreshes only on a lost-to-regained transition, using `wasSatisfied`
  and a hop to `@MainActor` from its background queue.
- `MemoryPressureMonitor` trims `CostUsageCache` and `ActivityCache` on warning/critical
  pressure, then calls `malloc_zone_pressure_relief` off-main. Preserve the cost disk
  checkpoint. Repopulate touched files later; do not reload the full cache immediately.
- `AppState.init(pipeline:)` skips all three system monitors and gives `setActive` an
  isolated defaults suite. Tests must not write `AppSettings.isActive` or save/restore
  shared pause settings; overlapping tests can leave the installed app paused.

## Notifications

- `NotificationEngine` is an actor. Quota policy takes fresh selected-provider
  `MainMeterReading` observations and thresholds from `AppGroupConfig`. Baselines must
  match provider and account identity; a switch starts a new baseline. Keep the old
  snapshot policy overload for Core compatibility tests. Claude attention hooks are
  separate from quota alerts.
- Codex home paths are pins. `observationOwnerID` defines alert ownership. Treat
  `CodexReadingStore.candidates` as untrusted until the poll verifies ownership off-main.
  Unknown-owner readings are current-only, with no durable cache or quota alerts.
- Dedup keys include provider, hashed account, scope, level, and reset epoch. Recognize
  legacy Claude keys. Critical suppresses warning. With no reset date, use the next
  local day's start. Mark fired only after `UNUserNotificationCenter.add` succeeds.
  Do not add sound.
- Recovery compares resolved current usage with raw previous severity so a reset can
  trigger a refueled alert. Notification copy uses energy left.
- Predictive alerts are opt-in and require two consecutive fresh qualifying observations
  with the same provider, account, scope, and reset epoch bucketed by 5 minutes.
  Normalize the hashed provider/account identity and recognize legacy keys. Stale,
  failed, or nonqualifying observations reset the streak. Fire only at normal severity.
- `SessionEventStore.drain` consumes subagent `Stop` markers with `agent_id` without
  notifying. Keep subagent permission and rate-limit/billing `StopFailure` events.
- `TerminalFocusRouter` activates a running terminal before detached exact focus.
  Route Ghostty by cwd, Terminal/iTerm2 by TTY, and WezTerm by pane ID. Warp only
  activates. Herdr routes pin its socket and pane ID for `herdr agent focus`; Ghostty
  uses `HERDR_STARTUP_CWD` for the outer terminal. Never use Herdr's inner TTY to select
  an outer terminal tab. Equal-cwd Ghostty windows remain ambiguous. Version 2 hook
  envelopes carry the base64url route; legacy filename routes remain readable. The
  snippet runs `ps`/`base64` only when `TERM_PROGRAM` is set.
  Guard scripts with `if application X is running` so a race cannot launch a quit app.
  Bound subprocess waits to 10 s, then SIGTERM/SIGKILL. AppleScript clients need the
  Automation entitlement and usage description and can show a one-time system prompt.
