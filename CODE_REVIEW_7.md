# Code Review: Claude Meter Phase 7 (`d73aac9`)

**Date:** 2026-06-22  
**Scope:** SQLite history store, usage trend chart, mini monitor, advanced diagnostics (commit `d73aac927ad3f95c8e3ad517579d4e239ffa270b`)  
**Status:** Findings addressed in follow-up commit.

---

## High

### 1. History retention hardcoded to 30 days

`HistoryStore.setupSchema()` prunes records older than 30 days. SPECS §15 advanced settings specify **180 days** default retention.

**Fix:** Make retention configurable via `historyRetentionDays` UserDefaults (default 180); pass into `HistoryStore` and prune on init and append.

### 2. Pruning only runs at store open

Records older than the retention window accumulate while the app stays running. `append()` never prunes.

**Fix:** Call retention prune after each `append()`.

---

## Medium

### 3. History records ignore privacy mode

`HistoryRecord(from:)` always stores `activeModel`. CSV/JSON export includes model names even in minimal/anonymous modes.

**Fix:** Omit model when `privacyMode.showsModel` is false.

### 4. Export and diagnostics block the main thread

`HistoryView.copyExport()` calls `exportCSV()` / `exportJSON()` from a `Task` on the MainActor, which `queue.sync`s into SQLite. `DiagnosticsView` calls `store.fetch()` synchronously in the view body to count records.

**Fix:** Add async export and count APIs on `HistoryStore`; use them from UI.

### 5. `rebuildPipeline()` does not refresh `historyStore`

`storeDirectory` and `historyStore` are set only in `init()`. Rebuilding the snapshot pipeline after settings changes leaves a stale history store reference if the backing directory ever changes.

**Fix:** Recreate `historyStore` and update `storeDirectory` in `rebuildPipeline()`.

### 6. History timestamps use `createdAt` not poll time

`HistoryRecord(from:)` uses `snapshot.createdAt` (parse time). Trend charts should anchor to `lastSuccessfulPollAt` when available.

**Fix:** Prefer `lastSuccessfulPollAt ?? createdAt`.

### 7. Diagnostics raw output not sanitized

Raw CLI output is shown verbatim when diagnostics are enabled. SPECS §16.4 requires redacting email and identifiers from logs by default.

**Fix:** Sanitize displayed raw output (emails at minimum).

---

## Low

### 8. Chart point IDs are unstable

`ChartPoint` uses `UUID()` per render, which can cause unnecessary chart redraws.

**Fix:** Derive stable IDs from record id + series.

### 9. Schema differs from SPECS §11.3

Table is named `history` with a simplified column set (no `raw_hash`, `session_id`, `total_cost_usd`). Acceptable Phase 7 simplification; note for future alignment.

### 10. `HistoryStoreTests` uses XCTest while other suites use Swift Testing

Both run under `swift test` but are reported separately (107 + 6). Consider consolidating later.

### 11. Mini monitor has no stale indicator

Popover shows stale state; floating HUD does not. Minor UX gap.

### 12. No history retention setting in UI

Retention is hardcoded; SPECS §15 lists it as an advanced setting.

**Fix:** Add slider in Advanced settings tab.

---

## Security

History export can leak model names when privacy mode is anonymous (finding #3). Diagnostics history section exposes full store path in UI (acceptable for local diagnostics, not copied to clipboard).

---

## What was working well

1. Thread-safe `HistoryStore` via serial `DispatchQueue` with `fetchAsync` for UI
2. WAL mode and indexed `created_at` column
3. `HistoryView` with Charts `LineMark`, range picker, and clipboard export
4. `MiniMonitorView` floating window via `NSViewRepresentable` level hook
5. Non-blocking history append via `Task.detached` from `AppState.poll()`
6. Six `HistoryStoreTests` covering append, fetch-since, prune, CSV, JSON, nullables
