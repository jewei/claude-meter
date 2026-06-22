# Code Review: Claude Meter Phase 3 (`29d5585`)

**Date:** 2026-06-22  
**Scope:** MenuBarExtra app shell — `AppState`, popover UI, menu bar label (commit `29d55854e0a2d9281b9229b3d057fe26b5d77b56`)  
**Status:** Findings addressed in follow-up commit.

---

## High

### 1. Fatal parse failures treated as success in `AppState.poll()`

`SnapshotPipeline.poll()` returns (does not throw) when parsing fails fatally. `AppState` always cleared `lastError` and reset backoff on any non-throwing return, silently ignoring `result.isFatal`.

**Impact:** Unauthenticated CLI, empty output, and other parse fatals appeared as success; stale snapshot could remain on screen with no error indication.

**Fix:** Check `result.isFatal`, set `lastError` from parse errors, and apply backoff without clearing the prior snapshot.

---

## Medium

### 2. Stale detection wrong on launch

`isStale` returned `true` whenever a cached snapshot existed but `lastPolledAt` was nil (`return snapshot != nil`). Launch always showed stale UI before the first poll.

**Fix:** Use `lastPolledAt ?? snapshot?.lastSuccessfulPollAt` as the freshness reference; restore `lastPolledAt` from disk on init.

### 3. `severity` forced to `.unknown` when stale

Menu bar tint fell back to `.primary` for stale-but-valid data because `severity` returned `.unknown` whenever `isStale` was true.

**Fix:** Derive severity from the snapshot when one exists; stale icon already handled separately in `MenuBarLabel`.

### 4. No refresh when popover opens

SPECS §8.3 calls for 15 s polling while the popover is visible. Interval only shortened on the next sleep cycle — opening the popover did not trigger an immediate poll.

**Fix:** Call `refreshNow()` when `isPopoverOpen` becomes true.

### 5. Decimal percentages truncated in UI

`Int(window.clampedPercent ?? 0)` displayed `84.5%` as `84%` in cards and menu bar label.

**Fix:** Add shared `displayPercent` formatting on `LimitWindow`.

### 6. `DateFormatter` recreated every SwiftUI body pass

`UsageCardView` exposed `timeFormatter` and `dateTimeFormatter` as computed properties, allocating new formatters on every render (and every 1 s ticker tick).

**Fix:** Use `static let` formatters.

### 7. Poll errors hidden when stale snapshot is shown

If a poll failed but an older snapshot remained, the popover still showed usage cards with no indication of the failed refresh.

**Fix:** Show a non-blocking poll-error banner above usage cards when `lastError != nil`.

### 8. Last persisted error not restored on launch

`SnapshotStore.readLastError()` existed but `AppState` never read it, so error state was lost across relaunches until the next poll.

**Fix:** Load `lastError` from store when no snapshot is available.

---

## Low

### 9. Settings gear and Quit not implemented

SPECS §7.3 lists gear and quit actions in the popover header. Deferred to Phase 5 per roadmap — acceptable for Phase 3 shell.

### 10. No app-level unit test target

`AppState` polling logic is untested. Extraction to `ClaudeMeterCore` deferred; core `displayPercent` covered via package tests.

### 11. `Color(hex:)` silently produces black on invalid input

`Scanner` failure leaves `rgb = 0`. Acceptable for fixed design tokens.

### 12. App sandbox disabled

`com.apple.security.app-sandbox = false` is required to spawn the local `claude` CLI subprocess.

---

## Security

No critical issues. App runs user-local CLI with minimal environment; no network calls. Privacy modes (Phase 5) not yet enforced in UI.

---

## What was working well

1. Clean `MenuBarExtra` + `.window` popover structure with `LSUIElement`
2. `AppState` as single `@MainActor` source of truth
3. Polling loop with popover-aware intervals and exponential backoff
4. Severity-tinted menu bar icon and animated loading spinner
5. `UsageCardView` accessibility labels and reset countdown logic
6. Preview helpers for SwiftUI development
7. Xcode project builds and links local `ClaudeMeterCore` package
