# Widget development rules

Follow the root [AGENTS.md](../AGENTS.md). See [SPECS.md](../SPECS.md), section 9,
for widget behavior.

- Open only `SnapshotStore.appGroup()`. Never fall back to Application Support or
  perform provider I/O. Load `main-meter.json` through Core's `MainMeterPublication`.
  It validates provider, exact account pin, and `selectionRevision`. Handle unavailable
  data as nil so a failed switch or clear cannot display the old meter.
- Keep rings with provider-supplied labels, outer long/weekly and inner short/session.
  Honor the shared progression setting. Medium and large widgets add Opus when present.
  Use the adaptive cream/dark `containerBackground`.
- Schedule the next timeline at the earliest future reset, stale deadline, or 15 minutes.
  Include `currentWeekOpus.resetsAt` when finding the next reset.
- Bundle Fredoka/Nunito with the widget's own `ATSApplicationFontsPath`. Keep `WFont`
  and `Color(widgetHex:)` local to this target; do not import app design tokens.
- With the macOS 26 SDK, the bundle file must import SwiftUI for `Widget`/`WidgetBundle`,
  even when it already imports WidgetKit.
