# Provider credentials and recovery

Providers are enabled in **Settings**, under **Data**. Credentials and the config dir
determine account ownership. Account labels do not prove which account is signed in.

Each source uses the following credentials:

| Source | Credential source | Credential owner |
| --- | --- | --- |
| Claude automatic | Each config dir's Claude Code Keychain entry, connected through automatic OAuth | Claude Code |
| Claude manual | Manually supplied OAuth credentials in Claude Meter's Keychain entry | Claude Meter |
| Codex | Each configured home's auth file with a subscription sign-in | Codex |
| Cursor | Local state database, with a read-only Keychain fallback | Cursor |
| Grok | Grok CLI auth file | Grok CLI |

## Claude recovery

Automatic mode requires a Claude Code sign-in. An expired or rejected credential needs
`claude login` for the affected config dir. Claude Meter does not refresh Claude Code
tokens.

Manual mode accepts OAuth credentials in **Settings**. Claude Meter stores and refreshes
these credentials in its own Keychain entry. A rejected refresh token requires
reconnection. Disconnect removes only that app-owned entry.

## Codex recovery

Codex requires a subscription sign-in. **Settings** supports additional Codex homes.
API-key sign-ins provide no subscription-quota reading.

For a missing, unreadable, expired, or rejected sign-in, Claude Meter can start one
temporary `codex app-server`. Codex owns refresh and credential storage. The process
exits after the recovery attempt. Failed recovery requires a new Codex sign-in for that
home. A new process cannot recover a sign-in stored only in another process's memory.

Network errors, server errors, rate limits, and missing quota do not start recovery.

## Cursor and Grok recovery

Cursor requires a local Cursor sign-in. Expired or rejected credentials require the user
to open Cursor and sign in again. Claude Meter does not refresh Cursor credentials.

Grok requires a Grok CLI sign-in. Expiry requires the user to open Grok or run `grok
login`. Claude Meter does not refresh Grok credentials.

## Retained readings

A temporary refresh failure can retain the last successful observation without changing
its time. Cards show the error, and expired stale limit windows become unknown. Pause
keeps readings. Disabling a provider clears them.

A missing pinned account stays unavailable until another account is selected by a drag
to the top of the list.

## Read-only limits and upgrade cleanup

"Read-only" describes provider usage reads and credentials owned by other apps. Manual
Claude OAuth is app-owned and can be updated. Codex can update its own credentials
during recovery.

One-time upgrade migrations remove obsolete Claude Meter hooks, statusline entries, and
owned artifacts. They do not install integration commands or remove provider
credentials. Diagnostics remove sensitive data before display, copying, or storage.
