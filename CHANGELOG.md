# Changelog

All notable changes to Claude Meter are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- Add entries under [Unreleased] as you work. On release, scripts/release.sh
     promotes this heading to the new version, stamps the date, and uses the
     section body as the GitHub release notes. Keep entries user-facing. -->

## [Unreleased]

### Added

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

[Unreleased]: https://github.com/jewei/claude-meter/compare/v1.2...HEAD
[1.2]: https://github.com/jewei/claude-meter/compare/v1.1...v1.2
[1.1]: https://github.com/jewei/claude-meter/compare/v1.0...v1.1
[1.0]: https://github.com/jewei/claude-meter/releases/tag/v1.0
