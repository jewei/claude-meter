# Claude Meter — Development Notes

## Build & test

```bash
# Full app build (no signing required for compilation checks)
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO

# Core library tests
swift test --package-path ClaudeMeterCore
```

App Group entitlement (`com.apple.security.application-groups`) requires a real provisioning profile to _run_; `CODE_SIGNING_ALLOWED=NO` is sufficient for compilation.

---

## Architecture

- **Main app** — `@MainActor final class AppState`, `MenuBarExtra` with `.window` style, `LSUIElement = YES` (no Dock icon)
- **Core library** — `ClaudeMeterCore` Swift package, no AppKit/SwiftUI deps, Swift 6 strict concurrency
- **Widget** — sandboxed `ClaudeMeterWidgetExtension`; reads from App Group container only (no `applicationSupport()` fallback)
- **Shared container** — `group.com.jewei.claudemeter`; `AppGroupConfig` centralises the suite name and syncs display settings
- **Project file** — `project.pbxproj` is hand-maintained; no xcodegen. Every new file needs a `PBXFileReference`, a `PBXBuildFile`, a group child entry, and a Sources/Frameworks build phase entry. Use consistent 24-char hex UUIDs throughout.

---

## Common mistakes

### Swift 6 concurrency

- **`ISO8601DateFormatter` is not `Sendable`** — mark `static let` formatters `nonisolated(unsafe)` when all access is protected by a serial queue. Same applies to `DateFormatter`, `NumberFormatter`, etc.
- **`DispatchQueue.sync` doesn't support `throws`** — use `Result { try work() }` captured in a `var`, then `result!.get()`. This is the `synchronized<T>` helper pattern used in `HistoryStore`.
- **`queue.sync` inside `queue.async` = deadlock** — async export wrappers (`exportCSVAsync`, `exportJSONAsync`, `recordCountAsync`) must call private queue-local helpers directly, not go through the `synchronized` wrapper which calls `queue.sync` again.
- **`actor` deinit** — deinit is non-isolated; accessing actor-stored `OpaquePointer` in deinit is technically a concurrency violation. Use `final class @unchecked Sendable` + serial `DispatchQueue` for C resource wrappers like SQLite.
- **`Task.detached` for fire-and-forget writes from `@MainActor`** — e.g., `Task.detached(priority: .utility) { try? store.append(record) }`. The store must be `Sendable`.

### Widget / App Group

- **Widget is sandboxed** — never fall back to `applicationSupport()` in widget code; the sandbox blocks it. Read from `SnapshotStore.appGroup()` only; return `nil` gracefully when unavailable.
- **macOS 26 SDK** — `Widget` and `WidgetBundle` protocols moved into `SwiftUI` module; `ClaudeMeterWidgetBundle.swift` needs `import SwiftUI` even though it uses `WidgetKit` types.
- **Design tokens can't be shared between app and widget targets** — widget target can't import app-target Swift files. Duplicate the `Color(hex:)` extension as `Color(widgetHex:)` in the widget. Intentional and acceptable.

### Parser & pipeline

- **`ClaudeOutputParser` — pass `now` per call, not at init** — if you store `now` at construction time, long-running sessions resolve reset times against launch time. The `parse(_:now:)` signature takes a per-poll timestamp; `SnapshotPipeline.poll(now:)` passes it through.
- **Stats command failure must not abort the status poll** — `mergeStats` is best-effort (`try?`). A failing `claude stats` returns `nil`; the status-only output continues to be parsed normally.
- **ANSI strip before auth detection** — run `ANSIStripper.strip` on raw output before checking `isUnauthenticated`. The CLI may emit ANSI escape codes around error text that break plain-text pattern matching.

### History store (SQLite)

- **`ORDER BY created_at ASC LIMIT N` drops newest rows** — when capping results, use `ORDER BY created_at DESC LIMIT N` then reverse the array, so a limit of 5000 keeps the most recent 5000 records, not the oldest 5000.
- **`Date.distantPast` with `ISO8601DateFormatter`** — formats as `"0001-01-01T00:00:00Z"`, which works fine for string comparison in SQLite since ISO8601 strings sort lexicographically.
- **`JSONEncoder` omits `nil` optionals** — it does _not_ encode `nil` as `null`; the key is simply absent. Don't assert `json.contains("null")` for a nil optional field.
- **Prune on append, not just on open** — call `pruneToRetentionCutoff()` inside `append`'s transaction so the DB stays bounded even if the process runs for weeks without restart.

### Staleness & UI

- **`lastPolledAt` must not advance on failed polls** — updating it on every attempt (success or failure) causes the footer to show "Just updated" even when the displayed data is stale. Only advance `lastPolledAt` on successful snapshot updates; derive staleness from `snapshot.lastSuccessfulPollAt`.

### Notifications

- **Notification dedup with nil `resetsAt`** — the dedup key uses `resetsAt` as the window anchor; if the parser can't extract a reset time, fall back to a daily anchor (start of today UTC) so notifications still fire on severity escalation rather than being silently suppressed.

---

## Diagnostics sanitizer

Always sanitize before logging or copying to clipboard:
- Email addresses → `[redacted]`
- Home directory paths (`/Users/<name>/…`) → `/Users/[redacted]/…`
- Labeled fields in CLI output (`Session name:`, `Organization:`, `Cwd:`, `Email:`, `Session id:`) → value replaced with `[redacted]`

---

## Deferred / known gaps

- `CommandRunner` pipe read only at process termination — large outputs risk pipe buffer deadlock
- `rebuildPipeline()` fires on every settings keystroke — needs debounce
- Non-zero exit code / stderr surfaced inconsistently in pipeline
- Raw output file not deleted when "Record raw CLI output" is toggled off
- Notification `markFired` called before delivery confirmation
- Explicit fsync on snapshot atomic writes
- Widget `resetText` uses `Date()` instead of `entry.date`
