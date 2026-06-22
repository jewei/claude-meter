# Code Review: Claude Meter Phase 6 (`c9b30d9`)

**Date:** 2026-06-22  
**Scope:** WidgetKit extension, App Group snapshot sharing (commit `c9b30d9e10bb920aef1509d4ff5cf10d4142ede2`)  
**Status:** Findings addressed in follow-up commit.

---

## High

### 1. Widget severity colors ignore user threshold settings

`WindowRow` uses `UsageThresholds.default` (hardcoded 80/95). The main app reads custom thresholds from `UserDefaults.standard`, but the widget extension cannot see the standard suite. Widget colors diverge from the popover and menu bar after the user changes Display settings.

SPECS §11.2: preferences should use the App Group `UserDefaults` suite when a widget is added.

**Fix:** Add `AppGroupConfig` in `ClaudeMeterCore` to sync display settings to the shared suite; widget reads thresholds from there.

### 2. No migration from legacy Application Support store

`AppState.makeStore()` prefers the App Group container but never copies an existing `current.json` from `~/Library/Application Support/ClaudeMeter/`. Upgrading users see empty widget data (and lose in-memory snapshot) until the next successful poll.

**Fix:** On first App Group use, migrate snapshot from Application Support when the shared store is empty.

### 3. Widget fallback to `applicationSupport()` reads the wrong container

The sandboxed widget extension's `applicationSupport()` resolves to its own container, not the main app's. The fallback never surfaces main-app data and is misleading.

**Fix:** Widget reads only from the App Group store.

---

## Medium

### 4. App Group identifier duplicated

`group.com.claudemeter.app` is hardcoded in `AppState` and `ClaudeMeterProvider`. A typo or rename in one place breaks sharing silently.

**Fix:** Centralize as `AppGroupConfig.suiteName` in `ClaudeMeterCore`.

### 5. Large widget always shows model name

`LargeWidgetView` renders `activeModel` without respecting privacy mode. In minimal/anonymous modes the popover hides identifiers.

**Fix:** Move `PrivacyMode` to `ClaudeMeterCore`; gate the model row using shared settings.

### 6. Widget does not indicate stale data

The popover shows a stale banner when `lastSuccessfulPollAt` exceeds `staleAfterSeconds`. The widget renders aged percentages with no visual cue.

**Fix:** Show a subtle stale indicator when data exceeds the shared stale threshold.

### 7. Widget reload skipped on unchanged snapshot

`reloadAllTimelines()` fires only when `result.snapshot` is non-nil after a successful parse. Acceptable because percentages usually change; timeline policy covers reset boundaries.

No code change required; noted for awareness.

---

## Low

### 8. Duplicated design tokens in widget target

Widget redefines hex colors locally instead of sharing `DesignTokens.swift`. Acceptable — WidgetKit targets cannot import app-target Swift files without a shared module.

### 9. No widget accessibility labels

SPECS §17 requires text equivalents for progress bars. Widget `WindowRow` lacks `.accessibilityLabel`.

**Fix:** Add combined accessibility labels to window rows.

### 10. Timeline refresh uses fixed 15-minute cap

`getTimeline` reloads at the nearest reset or 15 minutes. Combined with `reloadAllTimelines()` on each poll this is reasonable for Phase 6.

### 11. No unit test for App Group migration

Migration logic is untested.

**Fix:** Add `SnapshotStore` migration test.

---

## Security

App Group entitlements are correctly configured on both targets. Widget sandbox is enabled; main app remains unsandboxed with group access. Snapshot JSON in the shared container may contain email/session fields — large widget should respect privacy mode (finding #5).

---

## What was working well

1. `SnapshotStore.appGroup(suiteName:)` factory with directory creation
2. Small / medium / large widget layouts with consistent `WindowRow` component
3. Timeline policy schedules refresh at upcoming reset times
4. `WidgetCenter.shared.reloadAllTimelines()` after successful polls
5. Entitlements on app and extension targets match
6. Atomic JSON writes unchanged in shared store
