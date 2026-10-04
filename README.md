# Claude Meter

Claude Meter shows your coding quota for Claude, Codex, Cursor, and Grok in the macOS menu
bar, as energy left. Rings or bars show each account's session and weekly limits, and a
countdown shows when each limit resets.

<table>
  <tr>
    <th align="center">Light mode</th>
    <th align="center">Dark mode</th>
  </tr>
  <tr>
    <td><img src="docs/images/claude-meter-light-mode.png" alt="Claude Meter popover in light mode" width="406"></td>
    <td><img src="docs/images/claude-meter-dark-mode.png" alt="Claude Meter popover in dark mode" width="406"></td>
  </tr>
</table>

## Features

- A menu-bar bolt with a severity dot and the energy left in your session or weekly
  window.
- A hero that names the limit closest to running out and when it resets.
- One card per account: several Claude config dirs and Codex homes, with your own names and
  plan badges. Drag a Claude or Codex card to the top to choose the menu-bar account.
- Cursor billing usage and Grok credits on their own cards.
- Tokens used today, yesterday, and in the last seven days, from local sessions on this Mac
  (Claude Code, Codex, Grok) or from your Cursor account.
- Usage-limit resets and credits, when the provider reports them.
- Launch at login and signed automatic updates.

Usage refreshes every five minutes while the display is awake, and when you open the
popover if the data is more than a minute old. Nothing runs while the display sleeps.

## Privacy

Claude Meter reads quota with the sign-ins that Claude Code, Codex, Cursor, and Grok already
keep on your Mac. It never changes their credentials. The only credential it stores is a
Claude OAuth token that you paste into Settings yourself, in its own Keychain item.
Diagnostics and the optional log file remove tokens, emails, account IDs, and home paths.

## Install

Requires macOS 14 or later.

1. Download `ClaudeMeter-<version>.dmg` from the
   [latest release](https://github.com/jewei/claude-meter/releases/latest).
2. Open it and drag **Claude Meter** to **Applications**.
3. Open Claude Meter. Click the bolt in the menu bar, then **Get started**, and turn on your
   sources in **Settings > Data**.

Upgrading from 2.x? Update to 3.1.3 first; the update feed does this for you.

## Develop

`make check` builds and tests everything. See [docs/development.md](docs/development.md)
and [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE) © Jewei Mak

Claude Meter is an independent community project. It is not affiliated with, endorsed by,
or sponsored by Anthropic, OpenAI, Anysphere, or xAI. "Claude" is a trademark of Anthropic.
