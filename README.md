# Claude Meter

A macOS menu bar app that shows your Claude usage at a glance — your 5-hour
session and weekly limits as playful, color-coded **energy rings**, across every
account, with optional notifications.

<p align="center">
  <img src="assets/claude-meter-screenshot.png" alt="Claude Meter screenshot showing Claude and Cursor usage cards" width="600">
</p>

## Features

- **Menu bar meter** — an energy bolt + a nearest-limit status dot and your energy-left %, always visible.
- **Playful popover** — a combined-health hero and per-account **activity rings** (weekly + 5-hour), framed as energy remaining — plus a desktop widget, threshold notifications, launch at login, and auto-updates.
- **Multi-account aware** — run several `CLAUDE_CONFIG_DIR` accounts side by side (rate limits are per-account); give each a display name and plan badge.
- **Zero-config with Claude Code** — installs a transparent statusline bridge; no API keys needed.
- **Optional sources** — Claude Code OAuth usage API, the claude.ai usage API, and (opt-in) Cursor billing-period usage.
- **Private** — local-first; Claude credentials live in the macOS Keychain. Cursor reads the locally signed-in Cursor app's token store (read-only); nothing is logged.

## Requirements

- macOS 14+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (for the zero-config statusline source)

## Build

```bash
xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO  # compile
swift test --package-path ClaudeMeterCore                                    # core tests
```

Running the app requires a provisioning profile (App Group entitlement).

## Docs

- `SPECS.md` — full specification
- `AGENTS.md` — development notes
- `DESIGN.md` — UI design system and tokens

## License

[MIT](LICENSE) © Jewei Mak

## Disclaimer

Claude Meter is an independent, community project. It is not affiliated with,
endorsed by, or sponsored by Anthropic. "Claude" is a trademark of Anthropic.
