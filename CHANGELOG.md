# Changelog

Notable changes in each release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Entries for 3.1.3 and earlier
are in the `v3.1.3` tag.

<!-- Every user-visible change has an entry under [Unreleased] (AGENTS.md). scripts/release.sh
     turns the heading into the release version and uses the section as the release notes,
     so keep entries user-facing. Each entry describes a change against the last release
     (3.1.3, the v3.1.3 tag), never a fix of code that was not released. -->

## [Unreleased]

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
- The expand arrow is always last in the header of a bar card.
- The Grok mark has the same color as the other marks, not the color of its energy level.

### Fixed

- Codex usage with a fractional percentage no longer fails to load.
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
- A Codex CLI that is too old for usage checks asks you to update it.
