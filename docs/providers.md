# Provider setup and recovery

Enable each provider in Settings → Data. Account labels do not prove which account is
signed in; the credentials and config dir determine ownership.

| Source | Sign-in and credential source | Recovery |
| --- | --- | --- |
| Claude automatic | Sign in with Claude Code, then connect automatic OAuth. Each config dir uses its own Claude Code Keychain entry. | Run `claude login` for the affected config dir. Claude Meter does not refresh Claude Code tokens. |
| Claude manual | Connect manually supplied OAuth credentials in Settings. Claude Meter stores them in its own Keychain entry. | Claude Meter can refresh these app-owned credentials. Reconnect if the refresh token is rejected. Disconnect removes only this entry. |
| Codex | Sign in with Codex using a subscription account. Add other Codex homes in Settings. The normal read uses each home's auth file. | For a missing, unreadable, expired, or rejected sign-in, Claude Meter can start one temporary `codex app-server`. Codex owns refresh and credential storage. If recovery fails, sign in with Codex for that home. API-key sign-ins provide no subscription-quota reading. |
| Cursor | Sign in with Cursor, then enable Cursor in Settings. Claude Meter reads its local state database, with a read-only Keychain fallback. | Open Cursor and sign in again when credentials expire or are rejected. Claude Meter does not refresh them. |
| Grok | Sign in with the Grok CLI, then enable Grok in Settings. Claude Meter reads the CLI auth file. | Open Grok or run `grok login` when sign-in expires. Claude Meter does not refresh it. |

Ordinary Codex network errors, server errors, rate limits, and missing quota do not start
the recovery process. It exits after the recovery attempt. A sign-in stored only in
another process's memory cannot be recovered by a new process.

A temporary refresh failure can retain the last successful observation. Its time does
not advance. Cards show the error, and expired stale limit windows become unknown.
Pause keeps readings; disabling a provider clears them. A missing pinned account stays
unavailable until you select another account by moving its card to the top.

“Read-only” describes provider usage reads and credentials owned by other apps. Manual
Claude OAuth is app-owned and can be updated. Codex can update its own credentials during
recovery. One-time upgrade migrations remove obsolete Claude Meter hooks, statusline
entries, and owned artifacts. They do not install new integration commands or remove
provider credentials. Diagnostics are sanitized before display, copying, or persistence.
