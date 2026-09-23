# Claude Meter

A macOS menu bar app that shows your Claude usage at a glance — your 5-hour
session and weekly limits as playful, color-coded **energy rings**, across every
account.

<table>
  <tr>
    <th align="center">Light mode</th>
    <th align="center">Dark mode</th>
  </tr>
  <tr>
    <td><img src="assets/claude-meter-light-mode.png" alt="Claude Meter popover in light mode" width="406"></td>
    <td><img src="assets/claude-meter-dark-mode.png" alt="Claude Meter popover in dark mode" width="406"></td>
  </tr>
</table>

## Features

- **Current usage and resets** — provider usage and balances for Claude, Codex, Cursor, and Grok, with countdowns from reported reset times.
- **Menu bar meter** — an energy bolt + a nearest-limit status dot and your energy-left %, always visible.
- **Playful popover** — a combined-health hero and per-account **activity rings** (weekly + 5-hour), framed as energy remaining — plus launch at login and auto-updates.
- **Multi-account aware** — run several `CLAUDE_CONFIG_DIR` accounts side by side (rate limits are per-account); give each a display name and plan badge.
- **Claude OAuth** — connect Claude Code credentials or enter OAuth credentials in Settings.
- **Optional sources** — Cursor billing-period usage, multiple Codex homes, and Grok CLI credits. Claude or Codex can own the main meter. Cursor and Grok have separate cards.
- **Private** — no local transcript scanning or historical cost estimation. Provider credentials are read-only. Claude credentials remain in macOS Keychain; Cursor, Codex, and Grok read their own local sign-in state. Diagnostics are sanitized before display or persistence.

Usage refreshes every five minutes while the display is awake. Opening the popover
refreshes missing, failed, stale or at least one-minute-old readings. Reset countdowns
update locally. Display sleep stops refresh work; wake checks whether data needs refresh.

Codex normally reads subscription usage directly without starting a process. If credentials
need recovery, it runs one temporary Codex App Server and waits for it to exit. Codex owns
its credential refresh and storage; Claude Meter does not rotate or write those credentials.
API-key sign-ins do not supply ChatGPT subscription quota.

## Architecture

All four providers publish normalized accounts, quota windows and balances through
`UsageStore`. It owns readings, loading and refresh cancellation. `RefreshScheduler`
owns timing and admission. `AppState` owns presentation, settings and application coordination. Claude and Codex keep their existing last-good
storage inside their provider boundaries; disk work does not block the UI.

## Requirements

- macOS 14+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sign-in for automatic OAuth, or manually supplied OAuth credentials

## Install

1. Download the latest **`ClaudeMeter-<version>.dmg`** from the
   [releases page](https://github.com/jewei/claude-meter/releases/latest).
2. Open the DMG and drag **Claude Meter** into your **Applications** folder.
3. Launch it — the meter appears in your menu bar (there's no Dock icon).

The build is Developer-ID signed and notarized by Apple, so it opens without
Gatekeeper warnings. Updates are delivered automatically via Sparkle.

## Build

```bash
./scripts/verify-local.sh  # formatting, all package tests, Debug + Release unsigned builds
```

For a faster focused check, run `swift test --package-path ClaudeMeterCore`.

Release builds attach a versioned `.dSYMs.zip` to the GitHub release. The release
script verifies app symbol UUIDs against the shipped binary before
publication. Keep that archive for crash analysis; the local `build/` directory
is replaced by the next release build.

## Docs

- `SPECS.md` — full specification
- [AGENTS.md](AGENTS.md) — shared development rules and links to directory instructions
- `DESIGN.md` — UI design system and tokens
- [Issue workflow](docs/agents/issue-tracker.md) — GitHub issue and triage conventions

## License

[MIT](LICENSE) © Jewei Mak

## Disclaimer

Claude Meter is an independent, community project. It is not affiliated with,
endorsed by, or sponsored by Anthropic. "Claude" is a trademark of Anthropic.

Signed releases use local verification and notarized artifacts. See [release verification](docs/releases.md).
