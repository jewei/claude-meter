# Changelog

Notable changes in each release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Entries for 3.1.3 and earlier
are in the `v3.1.3` tag.

<!-- Every user-visible change has an entry under [Unreleased] (AGENTS.md). scripts/release.sh
     turns the heading into the release version and uses the section as the release notes,
     so keep entries user-facing. Each entry describes a change against the last release
     (the newest `v*` tag), never a fix of code that was not released. -->

## [Unreleased]

### Added

- Grok cards show the Grok logo.

### Changed

- Energy bars look deeper and glossier. When a limit will run out before it resets,
  "Runs out in …" shows with a warning icon, in orange, or in red when the limit is already
  almost empty, and in Energy left mode its bar hatches the shortfall up to the even-pace
  mark. "Lasts until reset" no longer shows as text; VoiceOver still says it.
- Tokens used shows Today, Yesterday, and Last 7 days as tiles: the estimated cost first
  ("$42.10"), the token count below. One note under the tiles says that the estimate uses
  API list prices and is not a bill, and explains a "+".
- Grok cards show "Weekly · 5% left" and the reset under the bar, as Claude and Codex
  cards do.
- Credit balances group thousands ("72,909.6 credits"), and "Usage limit resets" says
  "None available" instead of "0 available".

## [4.2.0] - 2026-10-27

### Added

- Token rows on Claude and Codex cards estimate the cost at API list prices, such as
  "35.8M tokens · ~$42.10". It is an estimate, not a bill. Prices come with the app; nothing
  is fetched.
- Optional alerts in Settings > Appearance: a macOS notification when a limit runs low,
  when it will run out before it resets, and when it refills. All are off until you turn
  them on.

- Cards say whether energy lasts until the reset: "Runs out in 2h 10m", "Tight: ~4% left
  at reset", or "Lasts until reset", with a mark on each bar and ring where an even pace
  would be. The summary at the top names the limit that runs out first. Claude, Codex,
  Cursor's billing period, and Grok's credits all show it.

### Changed

- In Low Power Mode, or when the Mac runs hot, Claude Meter refreshes every 15 minutes
  instead of 5, to save battery. Readings from the slower refresh are not marked stale.

### Fixed

- With several Claude accounts, one could show as stale for about a minute while
  refreshing still worked. Numbers now count as old after 15 minutes without a refresh,
  not 10.

## [4.1.2] - 2026-10-21

### Removed

- The colored severity dot on the menu-bar bolt, and its pulse at critical. The dot stayed
  bright on the menu bar of an inactive display. The popover still shows the severity, and
  the red `0` still shows when no energy is left.

### Fixed

- On the menu bar of an inactive display, the bolt and the number now dim as much as the
  other items. 4.1.1 dimmed them only a little.

## [4.1.1] - 2026-10-21

### Added

- Settings > Appearance has a **Window label** switch. Turn it off to show only the
  percentage in the menu bar, for example `92%` instead of `92% 5h`.

### Fixed

- The menu-bar item now dims on the menu bar of an inactive display, like the other items.

## [4.1.0] - 2026-10-06

### Changed

- The drag hint above the cards is now a tooltip on an info icon beside **ACCOUNTS**, and
  the **Menu bar** pill above the first card is gone, so the popover is two lines shorter.
  The top Claude or Codex card still sets the menu bar.
- Ring cards now open and close from their header, like bar cards, so usage-limit resets and
  tokens used can stay hidden. They start closed.
- While a provider rate-limits usage checks, the summary at the top says **Waiting to retry**
  with a countdown instead of **Refresh needed**, because the app retries by itself.
- Settings > Data shows each provider's logo on its tile.
- Settings calls a Codex home a "config dir", the same as for Claude: **Add config dir…**.
- You can now choose the plan badge of any Claude login in Settings > Data, also when the
  login reports a plan. Claude Code keeps the plan of the last sign-in, so after a plan
  change the badge could stay old. **Use reported plan** goes back to the reported badge.

### Fixed

- Claude Meter no longer asks for your login Keychain password to read Claude Code's
  sign-in. The dialog came back after each Claude Code token renewal, also after
  **Always Allow**.

## [4.0.0] - 2026-10-05

Claude Meter 4.0 is a complete rewrite. It keeps every feature of 3.x with a new, faster
core.

### Added

- Settings can disconnect Claude and remove a Claude config dir that you added. Removing a
  folder asks first, and so does a Disconnect that deletes tokens you entered.
- You can make the Settings window taller or shorter, and it always fits on the screen.
- A card's context menu has **Use in Menu Bar**, also as a VoiceOver action, so you can
  choose the menu-bar account without a drag.
- The welcome screen offers Quit.

### Changed

- Settings start fresh. After the welcome screen, connect Claude, turn on your other
  sources, and set your added folders, names, plans, appearance, and card order again.
  Launch at login and automatic update checks keep their setting.
- A manual Claude connection from 3.x must be entered again. When you connect Claude,
  Claude Meter deletes the old Keychain item.
- Settings always lists your Claude logins, also a single login and a login that has no
  config dir, so you can name each one and set its plan. A manual Claude connection can set
  its plan when the login does not report one.
- Settings opens as a normal window with a Dock icon while it is open, and no longer floats
  above other apps.
- The menu-bar card stays first. To use another account in the menu bar, drag its card to
  the top or use **Use in Menu Bar**. Moving the first card lower no longer changes the
  menu-bar account.
- A dragged card changes the order and the menu-bar account when you drop it, not while it
  passes the top of the list.
- Every percentage is a whole number, everywhere.
- Exactly 100% used now shows as out of energy in the menu bar as well as in the hero.
- "Last updated" shows hours and days for old data.
- The menu bar shows a passed reset and old data within 30 seconds, not only after a
  refresh.
- Cursor and Grok keep showing the last reading, marked stale, when the sign-in expires,
  until you sign in again. Signing out removes it.
- After a rate limit, Codex, Cursor, and Grok wait for the retry time before they ask
  again, at most one hour, and only for the limited login.
- When the Codex auth file cannot be read, the Codex card says what to do, and Claude Meter
  no longer starts the Codex CLI at each refresh.
- When a source that the menu bar does not show fails to refresh for a reason that no
  account of it shows, a notice at the top of the popover says why, with the source's name.
  Its cards show their accounts' own problems and mark old data, and no text shows twice.
- The expand arrow is always last in the header of a bar card.
- The Grok mark has the same color as the other marks, not the color of its energy level.

### Fixed

- Codex usage with a fractional percentage no longer fails to load.
- Turning off a Claude config dir that the menu bar uses no longer shows a warning. The
  menu bar then shows your other Claude accounts.
- Percentages on cards and in Appearance settings, and the extra-usage amount, keep their
  width when the value changes, so the text next to them stays in place.
- A failed manual Claude reconnection keeps the earlier working connection.
- Manual Claude tokens refresh before they expire, not only after a rejected request.
- Two people in the same Claude team are no longer marked as the same login.
- Cursor and Grok accept numbers sent as text, and a valid Grok sign-in of the same account
  is used when an expired one comes first.
- Reset countdowns from 12 to 48 hours round the hours down, so 47h 40m shows "47h", not
  "48h".
- The loading indicator in the menu bar spins, and it shows only before the first reading.
  During a later refresh, the bolt stays.
- Releasing a dragged card no longer opens or closes it.
- The popover fits on short screens.
- Text in light mode has enough contrast, also on hover and press.
- A saved card order no longer keeps Cursor, Grok, or extra usage first while a Claude or
  Codex card shows.
- A retry after a failed refresh keeps the error in the menu bar and the popover, instead
  of a spinner.
- When Codex keeps its sign-in outside `auth.json`, a Codex CLI that cannot start its
  usage service asks you to update it.

[Unreleased]: https://github.com/jewei/claude-meter/compare/v4.2.0...HEAD
[4.2.0]: https://github.com/jewei/claude-meter/compare/v4.1.2...v4.2.0
[4.1.2]: https://github.com/jewei/claude-meter/compare/v4.1.1...v4.1.2
[4.1.1]: https://github.com/jewei/claude-meter/compare/v4.1.0...v4.1.1
[4.1.0]: https://github.com/jewei/claude-meter/compare/v4.0.0...v4.1.0
[4.0.0]: https://github.com/jewei/claude-meter/compare/v3.1.3...v4.0.0
