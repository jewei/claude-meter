# Changelog

All notable changes to Claude Meter are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- Add entries under [Unreleased] as you work. On release, scripts/release.sh
     promotes this heading to the new version, stamps the date, and uses the
     section body as the GitHub release notes. Keep entries user-facing. -->

## [Unreleased]

### Changed

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
