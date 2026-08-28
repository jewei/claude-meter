# ClaudeMeterWidget — Development Notes

Widget gotchas. Loaded when Claude works under this directory.
Cross-cutting rules stay in the root `AGENTS.md`.

---

## Widget / App Group

- **Sandboxed** — never fall back to `applicationSupport()`; open only `SnapshotStore.appGroup()` and load through Core's `MainMeterPublication`, returning `nil` gracefully. That seam validates provider, exact pin, and `selectionRevision` against App Group settings so a failed switch/clear cannot display the old meter. The widget performs no provider I/O.
- **Activity-ring look** — depleting rings (outer long/weekly, inner short/session) + provider-supplied labels and energy rows; medium/large add an `opus` row when present; timeline refresh includes `currentWeekOpus.resetsAt`. Adaptive cream/dark `containerBackground`.
- **Fonts bundled into the widget too** — Fredoka/Nunito via the widget's own `ATSApplicationFontsPath`; widget-local `WFont` mirrors `PFont` (don't import app tokens).
- **macOS 26 SDK** — `Widget`/`WidgetBundle` live in `SwiftUI`; the bundle file needs `import SwiftUI` even though it uses `WidgetKit` types.
- **Design tokens aren't shared across targets** — duplicate `Color(hex:)` as `Color(widgetHex:)` in the widget. Intentional.
