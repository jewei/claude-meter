# Code Review: Claude Meter Phase 4 (`fd53dc2`)

**Date:** 2026-06-22  
**Scope:** `NotificationEngine`, `AppState` integration (commit `fd53dc2f1a0e8098de9502c0b3a61dec57166296`)  
**Status:** Findings addressed in follow-up commit.

---

## High

### 1. Notifications fire on level, not on threshold crossing

`evaluate()` posted whenever current severity was `.warning` or `.critical`, without comparing to the prior snapshot. A user already at 85% received a warning on every fresh dedup window, and steady-state polls could notify on relaunch even though no threshold was crossed.

SPECS §14 triggers say usage **crosses** a threshold.

**Fix:** Extract crossing detection into testable `NotificationPolicy` in `ClaudeMeterCore`; compare current vs previous `LimitWindow` per scope. `AppState` passes the pre-poll snapshot as `previous`.

---

## Medium

### 2. Stale data guard missing

SPECS §14.3.4: "Do not notify if data is stale." `process(snapshot:)` had no stale check.

**Fix:** Add `isStale` parameter; skip processing when true. `AppState` passes `false` after a successful fresh poll.

### 3. Dedup keys never pruned after reset window ends

SPECS §14.3.3: "Reset notification state after the corresponding reset time passes." UserDefaults keys accumulated indefinitely.

**Fix:** Prune keys whose embedded `resetsAt` epoch is in the past on each `process` call.

### 4. No `enableNotifications` toggle

SPECS §15 defaults `enableNotifications` to `true`, but the engine always posted when authorized.

**Fix:** Respect `UserDefaults` key `enableNotifications` (default `true`).

### 5. Authorization ignores provisional status

`isAuthorized()` only accepted `.authorized`. macOS can return `.provisional` for quiet delivery.

**Fix:** Treat `.authorized` and `.provisional` as permitted.

### 6. No unit tests for threshold logic

Crossing detection, dedup suppression, and jump-to-critical behavior were untested.

**Fix:** Add `NotificationPolicyTests` in `ClaudeMeterCore`.

---

## Low

### 7. Single-step jump to critical also posts warning path risk

Without crossing logic, a jump from 79% → 96% could theoretically evaluate warning before critical in separate code paths. Fixed by crossing policy (critical only).

### 8. Optional triggers not implemented (CLI unauthenticated, unparsable)

SPECS §14 triggers 5–7 deferred to Phase 5+ with settings/diagnostics wiring.

### 9. `markFired` before delivery confirmation

`UNUserNotificationCenter.add` is fire-and-forget; dedup marks optimistically. Acceptable for local notifications.

---

## Security

No issues. Local notifications only; no network. UserDefaults dedup keys contain no PII.

---

## What was working well

1. Actor-isolated `NotificationEngine` keeps UN center access off the main thread
2. Dedup keyed by `(scope, level, resetsAt)` survives relaunch
3. Warning suppressed when critical already fired for the window
4. `content.sound = nil` per SPECS §14
5. Authorization requested only when `.notDetermined`
6. `displayPercent` used in notification title
