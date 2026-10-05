# Product behavior

What the user sees and why. Each rule names the code that owns it; change the rule there and
here in the same commit. Provider contracts are in `docs/providers/`, the visual system in
`docs/design.md`, and the data flow in `docs/architecture.md`.

## 1. Concepts

1. **Energy left** is `100 − percent used`. Stored data is always percent used, 0–100.
   **Settings > Appearance > Show** can switch every number and fill to percent used.
2. A **limit window** is one provider limit: a session (≤ 24 h), a weekly window, a scoped
   window (one model, such as Opus), or a billing period. Only **binding** windows rank
   accounts and set severity (`QuotaWindow.isBinding`).
3. **Severity** uses percent used and the user's thresholds (`Thresholds`): normal below
   warning (default 80), warning below critical (default 95), critical below 100, and
   exhausted at 100 or more. Unknown when there is no value.
4. **Stale** data is shown, but marked. An account is stale when its provider says so, the
   last refresh failed, or its observation is more than 600 s old or more than 300 s in the
   future (`PresentationContext.isStale`).
5. **Resolution**: after a window's reset time, a current reading reads 0% used with no next
   reset; a stale reading reads unknown (`QuotaWindow.resolved`).
6. **Reset countdowns** use only provider-reported times and one format: `42m`, `3h 12m`,
   `36h`, `6d 7h` (`Countdown`). Never a calendar date.
7. **Percentages** are whole numbers, rounded to the nearest, except that a value above 0
   shows at least 1 and a value below 100 at most 99. So `0%` left appears only when the
   window is exhausted, and `100%` left only when nothing is used
   (`Formatting.wholePercent`, for text and speech alike).

## 2. The main meter

1. Only Claude or Codex can own the menu bar, the hero, and the first card
   (`ProviderID.canOwnMenuBar`). Claude is the default.
2. A provider is **in use** when its source switch is on; Claude also needs a connection
   (`Settings.enabledProviders`). Claude with its switch on but not connected neither
   refreshes nor shows a card or notice; Settings asks the user to connect it.
3. The chosen main provider owns the menu bar while it is in use. When it is not in use and
   the other main-capable provider is, the other one owns it, so a user who uses only Codex
   always gets a Codex meter (`PresentationContext.mainProvider`). This follows the user's
   settings, not failures: a provider that is in use keeps the meter while it fails or has
   no reading.
4. An exact account pin wins. Without a pin, the observed account nearest its limit wins;
   ties keep provider order (`AccountSelection.primary`).
5. A missing pinned account, a main provider that is in use without a reading, or no
   main-capable provider in use shows as unavailable with a reason. It never falls back to
   another account of the same provider, and a pin never falls back (`MainMeter`). Before
   the provider's first reading, a pin is not missing: the reason is `Claude has no usage
   reading yet.`, which is not a failure. The same applies while the reading is still the one
   saved by the last launch (`UsageStore.restored`), which keeps only accounts with an
   identity owner: a pin that it lacks waits for the first refresh to publish or fail.
6. The menu-bar dot shows the highest severity of the pinned account, or of every account of
   the provider without a pin.
7. Dragging a Claude or Codex card to the top of the list pins it and makes its provider
   the main meter. A drop in place of a first card that is not the main card does the same,
   so that card can always become the main meter. Only the card dropped on top changes the
   main meter: a move lower in the list keeps the main meter and every pin, also a missing
   pinned account. The main card stays first. While a Claude or Codex card is visible,
   Cursor, Grok, and extra usage cannot go first (`CardOrder.move`). The list shows the new
   order while the card moves, but the settings change once, when the user drops the card:
   a card that passes over the top and comes back changes nothing. During the drag, the card
   takes only places that the drop accepts, and the **Menu bar** pill moves to the card that
   the drop makes the main meter (`CardDragPreview`). **Use in Menu Bar** in a card's
   context menu, also a VoiceOver action, does the same as a drag to the top
   (`CardModel.canUseInMenuBar`). **Use automatic order** in Appearance clears the order and
   every pin.

## 3. Menu bar (`MenuBarModel`)

1. The icon is the bolt with a badge: a severity dot, a gray dot when stale, or a red `0`
   pill when exhausted. A spinner replaces it while the first reading loads, also of a pinned
   account that the saved reading lacks (`MainMeter.isLoadingFirstReading`); a warning bolt
   shows when there is no reading because something failed (`MainMeter.hasFailure`), also
   while a retry runs (`PresentationContext.isLoadingFirstReading`). Before
   setup, while paused, and before the first reading, the bolt has no badge.
2. The number follows **Menu bar shows**: `99% 5h` (session, or the weekly window with a
   `7d` suffix when there is no session value), `73% 7d`, or both joined by ` · `.
3. Paused and stale states hide the number. Paused and not set up dim the whole item; the
   spoken summary says `Paused.` or `Claude Meter. Not set up.`
4. One spoken summary names the provider, each shown window, and the overall severity, for
   example `Claude Meter. Claude. Session 15 percent left. Overall quota warning.`
5. The label refreshes on every store change and every 30 s.
6. When the severity becomes critical, the dot pulses three times, unless Reduce Motion is on.
   The view owns this animation (`MeterUI`); the model only reports the severity.

## 4. Popover (`PopoverModel`)

1. The header shows the main meter's observation age (`Just now`, `42s ago`, `12m ago`,
   `3h ago`, `2d ago`), Settings, and Quit.
2. The content is the first match of: welcome (onboarding), paused with no data, no source
   switch on, and accounts when any card shows. With no card, it is loading before the first
   reading, then an error screen for the first failed provider (main first; also while a
   retry runs), then setup help (which asks to connect Claude when its switch is on without a
   connection).
3. Every path into Settings from the popover finishes the welcome and starts updates.
4. Notices above the hero state, without repeats: the main provider's failed refresh, each
   main account's issue (prefixed with its name when there are several accounts), old data,
   and the failure of any other enabled provider that has no card. Issues with a retry time
   count down: `Anthropic is rate-limiting usage checks. Retrying in 3m.` Old data that no
   failed refresh explains gets its own notice, also beside other notices:
   `Claude data may be stale.`, or `Work: Data may be stale.` when only some accounts are old.
   When the meter is unavailable, the hero states the reason and no notice repeats that issue,
   also not with an account name in front (`Notice`).
5. The hero summarizes the main meter (`HeroModel`): its headline follows the selected
   account's severity, and its subline names the limiting window and its reset, or counts
   the accounts with plenty left ("fresh") and names the lowest account. Stale accounts are
   left out of that count and ranking, so old numbers never read as current.
6. Cards: one per account, in the user's order, with the main card first and a **Menu bar**
   pill. Without a main card, the first Claude or Codex card comes first
   (`CardOrder.ordered`). Automatic order is the main provider's accounts (selected first),
   Claude extra usage, the other main-capable provider, Cursor, then Grok. The extra-usage
   card shows only while Claude is the main meter, for its selected account, when that
   account reports extra usage (`CardBuilder`).
7. **Rings** cards are always open. **Bars**, Cursor, and Grok cards open and close, and
   remember their state. Details hold scoped windows, usage-limit resets, and tokens used.
8. A card shows its account's own issue. A card of a provider that is not the main meter also
   shows a failed refresh or old data; the main provider shows those as notices instead.
9. While the popover is open, countdowns and ages update every second.
10. When a background check finds an update that Sparkle did not show, the popover shows
    "Update available"; selecting it opens Sparkle's update window
    (`PopoverModel.showsUpdateNotice`, `Updater.isUpdateAvailable`).

## 5. Tokens used (`TokenRowsBuilder`)

1. Each card shows Today, Yesterday, and Last 7 Days (today plus six earlier local days).
2. Claude Code, Codex, and Grok counts come from local sessions in that account's own folder
   on this Mac, labeled **This Mac**. Cursor counts come from the account export, labeled
   **Account usage**. The label follows the source that the history reports.
3. Missing history is unknown (`—`), never zero. Notes state partial history, missing
   records, errors, and old data. An error with a retry time counts down, as notices do
   (`<message> Retrying in 3m.`). History never changes quota, severity, or selection.

## 6. Settings

1. **Data**: one switch per source, then each provider's accounts: Claude config dirs and
   connection, Codex homes, display names, and plan badges for logins that report none. Removing a
   config dir or a Codex home also removes its name, pin, and card state, and for a config dir
   its plan badge and switch (`Settings.forgetAccount`). Only the newest Connect or
   Disconnect applies its result. A Connect that is saved, and a Disconnect, refresh Claude, also when the connection mode stays
   the same. A Connect that fails, is abandoned, or is replaced saves nothing and refreshes
   nothing (`ClaudeSettingsModel`). Claude Code's active login with no config
   dir (`oauth-…`) is listed too, to name it and set its plan; it has no switch and no Remove. In
   manual mode, Settings shows the plan badge of the manual login, which reports no plan
   (`ClaudeSettingsModel.manualPlan`). A config dir is listed once by its canonical path. Removing a
   folder, and a Disconnect that would delete tokens that the user entered, ask first, inside the
   page (`DataSourceText.removeConfirmation`, `.disconnectConfirmation`). The removal question
   lists what its provider forgets. The implicit Codex home
   (`$CODEX_HOME` or `~/.codex`) has no Remove and cannot be added again, also before the list
   loads. A name edit for a Codex home that is no longer listed is dropped (`CodexSettingsModel`).
   A Codex home is listed once by its canonical path. Remove deletes every saved path of it,
   also a link left at the old path of a moved folder.
   Claude refuses a folder whose account key (its folder name) is already listed, names that dir,
   and asks to remove it first when the user added it, else to choose another folder. It drops a
   name edit for an account that is no longer listed. Cancel, and turning Claude off, abandon a
   running Claude Connect, never a Disconnect. When turning Claude off kept a Connect from being
   saved, the Claude subtitle says so while Claude is off; turning Claude on clears the note
   (`DataSourceText.claudeSubtitle`). A Disconnect turns the connection off even when the saved
   tokens cannot be deleted. A Disconnect of a manual connection whose delete fails says so, and
   the next reload (at launch, and each time the Data page of Settings shows) deletes a manual
   login that no manual connection uses, then removes that message (`ClaudeSettingsModel`).
2. **Appearance**: card style, energy left or used, the menu-bar window, warning and critical
   thresholds (warning 50–90, critical 60–100, steps of 5; critical stays above warning),
   and automatic order.
3. **Advanced**: fetch usage (pause), launch at login, automatic update checks, the log file,
   and Diagnostics. Diagnostics shows and copies redacted facts. A development or unsigned
   build cannot update itself (`Updater.isAvailable`) and shows only a note there.
4. **About**: version, links, license, credits, and the disclaimer.
5. Command-1 to Command-4 open the tabs. Settings opens as a normal window with a Dock icon.
   The app returns to menu-bar-only when the last titled window (Settings or Sparkle's update
   window) closes (`DockIconPolicy`).

## 7. First launch and upgrades

1. The first launch shows the welcome. Refreshing starts when the user opens Settings by any
   path: the popover, Command-comma, the app menu, or opening the app again from Finder
   (`AppController.openSettings`).
2. 4.0 starts with fresh settings. Installations older than 3.0 receive 3.1.3 first through
   the update feed, which removes 2.x hooks and files.
