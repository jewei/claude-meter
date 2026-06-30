# Changelog

All notable changes to Claude Meter are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- Add entries under [Unreleased] as you work. On release, scripts/release.sh
     promotes this heading to the new version, stamps the date, and uses the
     section body as the GitHub release notes. Keep entries user-facing. -->

## [Unreleased]

## [2.3] - 2026-06-30

### Removed

- The **Claude.ai web-session source** (Settings → Data) and its "Import from
  browser" cookie import. Claude Meter now collects usage from the **Statusline
  Bridge** and **Claude Code OAuth** only — trimming the app's most fragile and
  privacy-sensitive code (reading browser cookies). If you used only the
  claude.ai source, connect via the statusline bridge (just run Claude Code) or
  Claude Code OAuth.

## [2.2] - 2026-06-29

### Added

- **"Claude is waiting" notifications** — get a native macOS notification the
  moment a Claude Code session finishes its turn or asks for permission, so you
  can step away and get pulled back exactly when it needs you. Works across all
  your accounts. Turn it on under Settings → Notifications → Claude Attention
  (separate toggles for turn-finished and permission-needed).
- **Run-out forecast** — account cards project when you're on pace to hit a
  limit, not just how much energy is left right now.
- **Outdated Claude Code warning** — the popover footer flags when your installed
  Claude Code is behind the latest release and links to the changelog.

### Changed

- **More accurate cost estimates** — per-model pricing is now pulled live from
  models.dev, with corrected built-in fallback rates (Opus was previously
  over-estimated by roughly 3× when the live rates were unavailable).

### Fixed

- **Sturdier sign-in** — OAuth token refresh now prefers fresh in-memory
  credentials over a stale Keychain entry, avoiding spurious signed-out states.

## [2.1] - 2026-06-28

### Added

- An **activity heatmap** — tap the "Last 7 days" cost card to flip the popover to
  a GitHub-style punchcard showing when you actually work (day of week × hour of
  day, shaded by message volume), scanned from your local transcripts. Tap **Back**
  to return.
- A **"Menu bar shows"** setting (Appearance) to choose which window the menu-bar
  percentage reflects: nearest limit (default), the 5-hour window, the weekly
  window, or **both** side by side (e.g. `99% 5h · 73% 7d`).
- The **Claude Code version** now appears in the popover footer and links to the
  changelog.

### Changed

- Account cards show the weekly reset as a **calendar date** (e.g. "29 Jun")
  instead of a bare weekday.
- Removed the footer "Add account" button (adding an account already lives in
  Settings, reachable via the gear) to free up space.

## [2.0] - 2026-06-26

### Added

- Appearance settings (new Settings tab): pick **activity rings or energy bars**
  for the account cards, switch between showing **energy remaining or usage**, and
  **pin the menu-bar percentage to a specific account** (or the nearest limit).
- A complete visual redesign — a playful, energy-themed interface with a
  combined-health hero, per-account **activity rings** (weekly + 5-hour), and the
  whole app reframed as "energy remaining". Real Fredoka & Nunito typography and a
  refreshed green-bolt app icon.
- Per-account **display name** and **plan badge**, set in Settings → Data, so each
  account reads how you want (rate limits are per-account).
- A "refueled" notification when an account that was running low recovers — its
  window drops back to normal or resets.

### Changed

- The menu-bar icon is now an energy bolt with a nearest-limit status dot (across
  all your accounts) plus your energy-left percentage.
- Settings is fully restyled (Data / Notifications / Advanced / About) with a bold
  tab bar, color-coded threshold sliders, and roomier multi-account rows.
- The widget adopts the activity-ring look and adapts to light and dark.
- Cursor usage requests now use the shared redirect-guarded provider transport,
  matching the credential-leak protections used by Claude sources.
- OAuth-only enrichment for statusline/claude.ai snapshots is cached and
  throttled to reduce redundant usage API calls while keeping Opus/extra/plan
  fields visible between refreshes.

### Fixed

- Multi-account notifications now diff each account against its _own_ previous
  reading, so an active-account switch never fabricates a false threshold crossing
  nor skips a real one (switching to an already-critical account surfaces it once).
  A "refueled" alert still won't trigger from a stale/persisted reading on first
  launch or the first OAuth Opus enrichment.
- Disabling an account now clears any menu-bar pin to it (and the Appearance
  picker no longer lists disabled accounts); a lone non-default config dir shows
  its custom display name and plan badge in the popover.
- The menu-bar percentage and status dot are now Claude-only — Cursor usage no
  longer leaks into the menu bar (it kept its own popover card) and the menu bar
  honors the "Menu bar follows" account setting.
- OAuth refreshed-token cache is now scoped to the selected mode (`auto` vs
  `manual`) and cleared on disconnect, preventing tokens from crossing source
  modes inside one app session.
- Stale statusline/cache snapshots now mark the menu bar and popover as stale
  immediately instead of waiting for the age-based stale threshold.
- Medium widget now shows the Opus weekly window when available, matching the
  large widget and menu-bar severity.

## [1.3] - 2026-06-24

### Added

- Usage pace badge on each window card ("On track" / "Running hot" / "Room to
  spare"), comparing how much you've used against how far through the window you
  are — a glanceable read on whether you'll make it to the reset.
- Weekly Opus usage window, shown as its own card and factored into the menu-bar
  severity and notifications. For Max plans this is often the limit you hit first.
- Pay-as-you-go "Extra usage" overage spend (with a progress bar) is surfaced in
  the popover, including when overage billing is paused.
- Opus weekly, extra-usage spend, and plan now appear even on the statusline
  source: when OAuth is connected, those OAuth-only fields enrich the snapshot.
- Per-model token and estimated-cost breakdown for the last 7 days, scanned from
  local Claude Code transcripts and shown in the popover.
- Anthropic service-status banner in the popover during incidents, so an outage is
  distinguishable from expired credentials.
- Plan badge (Max/Pro/Team/Enterprise) in the popover header when detectable.
- "Import from browser" for claude.ai setup: reads the session key from Chrome,
  Brave, Edge, Arc, Firefox, or Safari and auto-detects the org — no manual paste.
- Diagnostics has a "Check browsers" action reporting per-browser cookie-import
  status (no secrets), to help troubleshoot the import.

### Changed

- Background polling is now energy-aware: it pauses entirely while the display or
  system is asleep (refreshing immediately on wake) and stretches its cadence while
  on battery, to cut idle power draw when you're away or unplugged.
- Network requests now go through a shared, redirect-guarded transport that blocks
  off-origin and HTTPS→HTTP redirects (so credentials can't leak), with bounded
  retries on transient failures. Keychain reads distinguish a momentary lock from
  missing credentials, so a locked Keychain no longer looks like "not connected".
- claude.ai setup now auto-detects your organization ID from the session key — the
  Org ID field is optional; leave it blank and Claude Meter resolves it for you.
- The OAuth usage source now backs off when Anthropic rate-limits (429), honoring
  `Retry-After`, and identifies as the Claude Code CLI. Usage decoding tolerates
  missing or null fields instead of failing the whole refresh.
- When paused, the menu bar shows only a dimmed icon and hides the usage
  percent, making the inactive state clearer.
- Release tooling derives the marketing version and build number automatically,
  bakes them into the build, and uses this changelog as the GitHub release notes.

### Fixed

- OAuth enrichment now shares the same 429 backoff as the main OAuth pipeline, so
  statusline-primary users no longer hammer the usage API after a rate limit.
- Plan badge no longer disappears after an in-session OAuth token refresh
  (`subscriptionType` is preserved).
- Menu-bar usage percent now reflects the binding limit (including Opus weekly),
  matching severity icon semantics.
- Browser cookie import matches `claude.ai` hosts exactly (not substring matches
  like `evilclaude.ai`).
- Cost estimates label "partial" when large transcript files are tail-read; dedup
  no longer collapses messages missing ids.
- Pace badges treat implausible `resets_at` values as unknown instead of
  clamping to misleading hot/cold readings.
- PowerMonitor no longer parks polling on `willSleep` (cancelled sleep could
  stall refreshes for up to 5 minutes).
- Poll and cursor errors shown in the UI are sanitized like bridge diagnostics.
- Service-status fetch runs concurrently with usage polling (no longer blocks the
  primary refresh).
- Widget shows Opus weekly when available; release script tags the release commit
  (not pre-build HEAD) and reads `TEAM_ID`/`APPLE_ID` from env.

## [1.2] - 2026-06-24

### Added

- Cursor as an optional, opt-in usage source alongside Claude.

### Changed

- Hardened the core pipeline for correctness and steadier polling.

## [1.1] - 2026-06-24

### Added

- Statusline bridge and OAuth usage API as primary data sources.
- Per-source toggles and active-state handling.
- App icon, plus onboarding and settings polish.

### Changed

- More resilient usage data sources and diagnostics.

### Fixed

- Usage flicker, idle staleness, and the refresh spinner.

### Removed

- SQLite history store and the floating mini monitor.

## [1.0] - 2026-06-23

### Added

- Menu bar usage meter for Claude Code with five-hour and weekly rate-limit windows.
- Data-source fallback: statusline bridge → OAuth usage API → claude.ai API → cached snapshot.
- Local notifications with threshold deduplication.
- WidgetKit widget sharing snapshots via an App Group.
- Settings panel and diagnostics view.
- Sparkle auto-update support.

[Unreleased]: https://github.com/jewei/claude-meter/compare/v2.3...HEAD
[2.3]: https://github.com/jewei/claude-meter/compare/v2.2...v2.3
[2.2]: https://github.com/jewei/claude-meter/compare/v2.1...v2.2
[2.1]: https://github.com/jewei/claude-meter/compare/v2.0...v2.1
[2.0]: https://github.com/jewei/claude-meter/compare/v1.3...v2.0
[1.3]: https://github.com/jewei/claude-meter/compare/v1.2...v1.3
[1.2]: https://github.com/jewei/claude-meter/compare/v1.1...v1.2
[1.1]: https://github.com/jewei/claude-meter/compare/v1.0...v1.1
[1.0]: https://github.com/jewei/claude-meter/releases/tag/v1.0
