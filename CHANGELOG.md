# Changelog

Notable changes in each release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Entries for 3.1.3 and earlier
are in the `v3.1.3` tag.

<!-- Add entries under [Unreleased] as you work. scripts/release.sh turns the heading into
     the release version and uses the section as the release notes. Keep entries
     user-facing. -->

## [Unreleased]

Claude Meter 4.0 is a complete rewrite. It keeps every feature of 3.x with a new, faster
core.

### Changed

- Settings start fresh. After the welcome screen, connect Claude and turn on your other
  sources again, and set names, plans, and card order.
- A manual Claude connection from 3.x must be entered again. Claude Meter deletes the old
  Keychain item.
- Settings lists a Claude login that has no config dir, so you can name it and set its
  plan.
- The popover is a native panel that resizes smoothly when you open and close cards.
- Settings opens as a normal window with a Dock icon while it is open, and no longer floats
  above other apps.
- The Settings window can be resized, and always fits on the screen.
- A card's context menu has **Use in Menu Bar**, also as a VoiceOver action, so you can
  choose the menu-bar account without a drag.
- Removing a folder, and a Disconnect that deletes tokens you entered, ask first.
- The welcome screen offers Quit.
- Every percentage is a whole number, everywhere.
- Codex windows are named Session and Weekly, the same as Claude.
- Exactly 100% used now shows as out of energy in the menu bar as well as in the hero.
- "Last updated" shows hours and days for old data.
- The menu bar updates countdowns and staleness every 30 seconds, not only after a refresh.
- Cursor and Grok keep showing the last reading, marked stale, when the sign-in expires,
  until you sign in again. Signing out removes it.

### Fixed

- Codex usage with a fractional percentage no longer fails to load.
- A Codex request that times out names the step that timed out.
- A failed manual Claude reconnection keeps the earlier working connection.
- Manual Claude tokens refresh before they expire, not only after a rejected request.
- Two people in the same Claude team are no longer marked as the same login.
- Cursor and Grok accept numbers sent as text, and a valid Grok sign-in is used even when
  an expired one comes first.
- Reset countdowns between 47h 30m and 48h no longer show "48h".
- The loading indicator in the menu bar spins.
- The popover closes when you switch apps or Spaces, and a click on the menu-bar icon
  right after it closed no longer opens it again.
- Releasing a dragged card no longer opens or closes it.
- The popover fits on short screens and with a hidden menu bar.
- Text has enough contrast in light and dark mode, also on hover and press.
- Moving a card lower in the popover no longer changes the menu-bar meter or its pinned
  account.
- A saved card order no longer keeps Cursor, Grok, or extra usage first while a Claude or
  Codex card shows.
- A retry after a failed refresh keeps the error in the menu bar and the popover, instead
  of a spinner.

### Removed

- The one-time cleanup of 2.x hooks, statusline commands, and cache files. Installations
  older than 3.0 receive 3.1.3 first, which does this cleanup.
