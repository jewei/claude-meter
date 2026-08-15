# ClaudeMeterWidget — Development Notes

Widget gotchas. Loaded when Claude works under this directory.
Cross-cutting rules stay in the root `AGENTS.md`.

---

## Widget / App Group

- **Sandboxed** — never fall back to `applicationSupport()`; read `SnapshotStore.appGroup()` only and return `nil` gracefully.
- **Activity-ring look** — depleting rings (outer weekly, inner 5-hour) + energy rows; medium/large add an `opus` row when present; timeline refresh includes `currentWeekOpus.resetsAt`. Adaptive cream/dark `containerBackground`.
- **Fonts bundled into the widget too** — Fredoka/Nunito via the widget's own `ATSApplicationFontsPath`; widget-local `WFont` mirrors `PFont` (don't import app tokens).
- **macOS 26 SDK** — `Widget`/`WidgetBundle` live in `SwiftUI`; the bundle file needs `import SwiftUI` even though it uses `WidgetKit` types.
- **Design tokens aren't shared across targets** — duplicate `Color(hex:)` as `Color(widgetHex:)` in the widget. Intentional.
