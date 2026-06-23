# Multi-Model Code Review: Last 2 Commits

**Scope:** `17574e4` (archive warnings fix) + `0758b2a` (Sparkle auto-update)

**Intent:** Integrate Sparkle 2.x for background update checks and manual "Check for Updates…", with gentle scheduled reminders shown as a tappable popover notice instead of interrupting the user. Also add `LSApplicationCategoryType`, `AccentColor`, EdDSA public key, and an `appcast.xml` template.

**Models:** GPT 5.5 High, Claude Opus 4.8, Composer 2.5

**Date:** 2026-06-23

---

## Consensus (2+ models)

### 1. Update notice hidden in non-usage popover states — **warning** (3/3)

The banner lives only inside `usageState(_:)`, but `mainContent` routes loading/error/setup elsewhere when `snapshot == nil`. If Sparkle sets `updateAvailable` while the user is in setup/error/loading, they never see the reminder.

**Verdict: Consider** — hoist the notice above the state branch, or duplicate it in each state.

### 2. Production appcast not release-ready — **warning** (3/3)

`SUFeedURL` points at `main/appcast.xml`, which still has `PLACEHOLDER_REPLACE_WITH_SIGNATURE` and `length="0"`. Publishing a higher `sparkle:version` without signing breaks updates fleet-wide.

**Verdict: Act on before first release** — gate appcast updates on CI signing (`generate_appcast` + real `length`).

### 3. No `Package.resolved` / floating Sparkle version — **nit** (2/3)

Sparkle is `upToNextMajorVersion` from `2.0.0` with no committed lockfile. Builds may resolve different 2.x versions over time.

**Verdict: Consider** — commit workspace `Package.resolved` after resolving.

---

## Lone-Model Findings

| Finding | Model | Verdict |
|---------|-------|---------|
| **Feed served from `main`** — any merge affects all clients | Composer | **Consider** — release-scoped feed is safer |
| **LSUIElement + popover-only reminder** — users who never open popover miss updates | Composer | **Consider** — notification or activation-policy pattern per Sparkle docs |
| **Update modals may open behind other apps** without `NSApp.setActivationPolicy(.regular)` | Composer | **Consider** — verify on hardware |
| **`immediateFocus` still allows launch-time modals** | Composer | **Noted** — intentional per Sparkle sample; tune if unwanted |
| **No in-app toggle for automatic checks** despite `SUEnableAutomaticChecks` | Composer | **Noted** — add preference or document |
| **`MainActor.assumeIsolated` in delegate** — crashes if Sparkle ever calls off-main | Composer | **Noted** — `Task { @MainActor in }` is safer |
| **Test/preview init never sets `delegate.appState`** | Composer | **Noted** — preview won't exercise reminder UI |
| **`updaterController` is public** | Composer | **Dismissed** — minor API surface |
| **`pubDate` weekday wrong** (Mon vs actual Tue) | Opus | **Dismissed** — cosmetic |
| **Malformed 26-char package UUID in pbxproj** | Opus | **Dismissed** — false positive; committed file uses correct 24-char ID |

---

## Disagreements

- **Opus "critical" pbxproj UUID mismatch:** Not present in the actual diff or working tree. Dismissed.
- **Composer "critical" appcast:** Downgraded to **warning** — real risk, but expected for a template not yet wired to releases.

---

## What All Reviewers Agreed Looks Correct

- Sparkle delegate API usage (`supportsGentleScheduledUpdateReminders`, `immediateFocus`, `!handleShowingUpdate` → flag) matches Sparkle's gentle-reminders sample
- `startingUpdater: true` in production vs `false` in test init
- Sparkle linked only to main app, not widget extension
- App is not sandboxed (required for in-place updates)
- `SUPublicEDKey` in plist is expected (public key only)
- `sparkle:minimumSystemVersion` 14.0 aligns with deployment target
- AccentColor / `LSApplicationCategoryType` changes are fine for silencing archive warnings

---

## Recommended Actions

| Priority | Action | Status |
|----------|--------|--------|
| **Before shipping updates** | Automate appcast signing; never publish unsigned/higher-version items to the live feed | Documented in `appcast.xml` comment |
| **UX** | Hoist update notice so it shows in all popover states | Fixed |
| **Release hygiene** | Commit `Package.resolved`; pin Sparkle to minor version | Fixed |
| **Optional polish** | Activation policy for LSUIElement modals; auto-check preference in Settings; wire `delegate.appState` in test init; update notification; safer main-thread dispatch | Fixed |

---

## Fixes Applied (2026-06-23)

1. **PopoverView** — moved `updateAvailableNotice` above `mainContent` so it appears in all popover states.
2. **AppState** — `updaterController` made private; test init wires `delegate.appState`; delegate uses `Task { @MainActor in }`; activation policy switches to `.regular` when showing update UI and back to `.accessory` when session ends; `checkForUpdates()` activates app first.
3. **NotificationEngine** — posts a local notification when a gentle update reminder fires (respects notification settings).
4. **SettingsView** — added "Check for updates automatically" toggle bound to `SUEnableAutomaticChecks`.
5. **appcast.xml** — fixed `pubDate` weekday; added release-signing comment.
6. **project.pbxproj** — Sparkle pinned to `upToNextMinorVersion` from 2.9.3.
7. **Package.resolved** — committed with Sparkle 2.9.3 pin.

**Not changed (requires release workflow):** `SUFeedURL` still points at `main`; appcast placeholder signature must be replaced at release time via `generate_appcast` or equivalent CI step.
