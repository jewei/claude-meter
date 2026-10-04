# Claude provider

`Sources/ProviderClaude` reads Claude quota. Read this document before you change the
provider. If you change a contract or a rule, change this document in the same commit.

Terms: a **config dir** is a Claude Code configuration folder (`~/.claude`,
`~/.claude-work`). An **account key** is the `AccountID` of a config dir. The **active login**
is the Keychain item that Claude Code uses now.

## External contracts

### Usage request

```text
GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
Accept: application/json
User-Agent: claude-cli/2.1.280 (external, cli)
```

1. Send the request with `retry: .never` and a 15 s deadline.
2. Keep `cedar_ember=1`. Without it, the response has no usage-limit resets.
3. Keep the User-Agent format `claude-cli/<version> (external, cli)`. The server decides
   reset eligibility from it. The old `claude-code/<version>` form gets
   `ineligible_reason: "surface"`.
4. HTTP 200 is usage. 401 and 403 mean the token was rejected. 429 closes the rate-limit
   gate. Other status codes are failures with the status in the text.

### Usage response fields read

| Field | Use |
| --- | --- |
| `five_hour.utilization`, `.resets_at` | Session window |
| `seven_day.utilization`, `.resets_at` | Weekly window |
| `seven_day_opus` | Opus Weekly window, only when `utilization` has a value |
| other `seven_day_<scope>` objects | Scoped windows, only when `utilization` has a value |
| `limits[]` with `kind: "weekly_scoped"` | Fills scoped windows that the flat fields do not have |
| `extra_usage.{is_enabled, used_credits, monthly_limit, decimal_places, utilization, currency}` | Extra usage window and balance |
| `cedar_ember.{eligible, ineligible_reason, grants[]}` | Usage-limit resets |
| `grants[].{label, resets_left, starts_at, ends_at}` | One reset grant |

`resets_at`, `starts_at`, and `ends_at` can be ISO-8601 text (any fraction length) or epoch
numbers. `utilization` is percent used, 0 through 100.

### Token refresh request (manual mode only)

```text
POST https://console.anthropic.com/v1/oauth/token
Content-Type: application/json

{"client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e","grant_type":"refresh_token","refresh_token":"<R>"}
```

1. The response has `access_token` (required), `refresh_token` (optional; when it is not
   there, keep the old one), and `expires_in` in seconds (required).
2. The new expiry is now plus `expires_in`, limited to 300 s through 604,800 s.
3. HTTP 400, 401, or 403 with `invalid_grant` in `error` or `error_description` means the
   refresh token is dead. All other failures are temporary.

### Keychain items

| Item | Service | Account | Access |
| --- | --- | --- | --- |
| Claude Code, legacy | `Claude Code-credentials` | macOS user name | Read only |
| Claude Code, per config dir | `Claude Code-credentials-<h>` | macOS user name | Read only |
| Manual login (app-owned) | `com.jewei.claudemeter.claude-oauth` | `manual` | Read, write, delete |

1. `<h>` is the first 8 lowercase hex characters of the SHA-256 of the config dir's path.
   The path is absolute, has symbolic links resolved, is standardized, and has no trailing
   slash (`ConfigDirectoryScanner.canonicalPath`). Example: `/Users/jewei/.claude-oneone-tech`
   gives `Claude Code-credentials-48c8f98c`.
2. The default dir tries the legacy item first, then its hashed item. Other dirs use only
   their hashed item.
3. Claude Code's item value is
   `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt" (epoch ms),
   "subscriptionType", "rateLimitTier"}}`. `accessToken`, `refreshToken`, and `expiresAt` are
   required.
4. The manual item value is JSON `{accessToken, refreshToken, expiresAt, subscriptionType,
   connectionID}` with ISO-8601 dates. `expiresAt` is the real expiry or absent.
5. Sign-in status checks read item attributes only, never a secret.

### Files read

| Path | Fields |
| --- | --- |
| `~/.claude*/` | Existence of `settings.json` or `projects` |
| `~/.claude.json` (for `~/.claude`) or `<config dir>/.claude.json` | `oauthAccount.accountUuid`, `.organizationUuid`, `.organizationRateLimitTier`, `.userRateLimitTier` |

The `.claude.json` read scans the file in 256 KiB chunks and keeps only the top-level
`oauthAccount` object, so a large file (Claude Code keeps per-project state in it) costs
little memory. The limit is 256 MiB. The result is one of three states:

- found: the file has a top-level `oauthAccount` object;
- absent: no file, not a regular file, or a complete file without that object;
- unreadable: the file ends before its root object does (Claude Code is writing it), is
  larger than the limit, or the read fails or takes more than 5 s.

### Stored values

| Key | Store | Value |
| --- | --- | --- |
| `claude.rateLimitedUntil` | Injected `KeyValueStore` | JSON `{"recordedAt": ISO-8601, "until": ISO-8601}` |

## Rules

### Accounts

1. The account key is the folder name without one leading dot, with only `[A-Za-z0-9._-]`
   kept. An empty key is `claude`. Never change this algorithm: settings store these keys.
2. The label is `default` for `claude`, the part after `claude-` for `claude-<name>`, else
   the key.
3. Discovery lists `~/.claude` when it exists, other `~/.claude-*` dirs that have
   `settings.json` or `projects`, and the configured dirs.
4. Two dirs with the same resolved path are one account. Two dirs with the same key keep
   one: `~/.claude` owns `claude`, then a configured dir wins, then the smaller path.
5. Order: the default account first, then the others by key.
6. The default account `claude` can never be disabled. Disabled accounts are listed but not
   read and have no card.
7. A configured dir that is gone or no longer has `settings.json` or `projects` is listed
   with an issue that asks the user to remove it. It is not read.
8. The active login is the legacy item when it exists, else the most recently modified
   hashed item (equal dates: the smallest service name). It belongs to the config dir whose
   services contain it. A legacy item without `~/.claude` belongs to `claude` and uses `~/.claude.json`. A hashed item
   that matches no config dir gets its own account `oauth-<first 8 hex of SHA-256 of the
   service>`, shown first.

### Automatic mode

1. Claude Meter never refreshes, writes, or deletes Claude Code's credentials.
2. A token that expires within 60 s is expired. Expired tokens are not sent.
3. The account of the active login is read on every refresh. With no active login, or while
   the Keychain cannot say which login is active, that is `claude`.
4. Every other enabled account is read when it has no previous value, or its previous
   `attemptedAt` is at least 300 s old. A failed attempt counts, so an account that always
   fails is also requested at most every 300 s. Otherwise its previous value is returned
   unchanged.
5. Requests go out one at a time: the active login first, so that a 429 never starves the
   menu-bar account, then the others in output order. The output order does not change.
6. After each response, the credential and identity are read again. If the owner changed,
   the response is discarded.
7. Each account has 20 s, inside the 60 s budget of the whole refresh. An account that runs
   out of time keeps its previous observation, marked stale. When the budget ends, the
   accounts that did not start keep their previous value and `attemptedAt`, and the finished
   accounts are kept.
8. While the Keychain cannot say which login is active (locked, or the read timed out), the
   account of that login keeps its reading, marked stale with the Keychain issue. That is an
   unmapped `oauth-…` account, or `claude` when `~/.claude` does not exist. When no account
   is left, the refresh throws the Keychain issue and keeps the last reading. A locked
   Keychain never shows as "not signed in".

### Manual mode

1. Manual mode has one account, `claude` (`default`).
2. Connect sends one usage request with the new tokens, then saves them. A token that
   expires within 60 s is refreshed first. A failure leaves the old manual login unchanged.
3. A token is refreshed when it expires within 60 s, and once after HTTP 401.
4. Callers with the same refresh token share one token request.
5. Connect and disconnect start a new generation. A refresh from an older generation cannot
   save or change anything. Keychain writes are ordered, so a late save cannot restore a
   deleted item.
6. A refresh token rejected with `invalid_grant` is not sent again. After a temporary
   failure, refreshes wait 5 minutes, doubling up to 6 hours.

### Rate-limit gate

1. One gate serves all accounts, both modes, and Settings verification.
2. HTTP 429 blocks requests for `Retry-After` (seconds or an HTTP date). A missing, invalid,
   zero, or past value blocks for 60 s. The block is at most 24 hours.
3. A later, shorter 429 never shortens a block. A longer one extends it.
4. A 429 stops the rest of the refresh. Accounts that were not attempted keep their previous
   value and `attemptedAt`. An account with no previous value shows the rate limit.
5. When the gate is closed at the start of a refresh, the refresh throws a `ProviderError`
   with `retryAt` and sends nothing.
6. The deadline is stored under `claude.rateLimitedUntil`. Loading never extends it. An
   invalid, expired, or longer-than-24-hours record is removed.

### Retention and owners

1. The owner of an observation is `.identity(sha256(parts: ["claude", accountUuid,
   organizationUuid]))` from `.claude.json` when it names an account. When the file is
   absent or names no account, it is `.credential(sha256(accessToken))`. When the file is
   unreadable, the owner is unknown (`OwnerStatus.unknown`): the reading is kept, and no
   request goes out for that account until the file can be read.
2. The manual owner is `.identity(sha256(parts: ["claude", "manual", connectionID]))`. The
   connection ID is random and made at connect time.
3. A failed account keeps its last observation, marked stale, only while
   `AccountUsage.belongs(to:)` allows it. A locked Keychain keeps it. Sign-out or a different
   owner drops it.
4. `reconcile` drops accounts that left the configuration and observations whose owner
   changed. It uses local reads only.
5. Accounts whose `.claude.json` has the same `accountUuid` and `organizationUuid` get
   `sharesLogin = true`. One person in two organizations has two quotas, so two logins.

### Mapping

1. Windows, in order: `session` "Session" (session), `weekly` "Weekly" (weekly),
   `seven_day_opus` "Opus Weekly" (scoped), other scoped keys "<Scope> Weekly" sorted by key
   (scoped), `extra-usage` "Extra usage" (billing).
2. Session, weekly, and Opus windows are binding. Other scoped windows and extra usage are
   not.
3. Session and weekly windows are always present; unknown values stay unknown, never 0.
4. A flat `seven_day_<scope>` field with a value wins over `limits[]`. A `limits[]` key is
   `seven_day_` plus the first word of the model name that is not "Claude", lowercased. The
   first entry per key wins.
5. Extra usage: amount and limit are minor units divided by `10^decimal_places` (default 2,
   0 through 18) as exact decimals. The percent is `utilization`, else used over limit. The
   currency is upper case, `USD` when missing. `is_enabled: false` is paused.
6. Usage-limit resets: `eligible: false` with `ineligible_reason: "surface"` is unknown (nil).
   Any other `eligible: false` is zero resets. Keep grants with `resets_left > 0` that have
   started and not ended. An empty label is "Usage reset". Each grant counts at most 99.
7. The plan is from the credential's `subscriptionType` and `rateLimitTier`, else the
   `.claude.json` tier: "Max 20x", "Max 5x", "Max", "Pro", "Team", "Enterprise", "Free".

### Limits

| Work | Limit |
| --- | --- |
| Config dir discovery | 5 s |
| One Keychain or file read | 5 s (`BlockingIO`) |
| One HTTP request | 15 s |
| One account in automatic mode | 20 s, inside the refresh budget |
| One whole refresh | 60 s; automatic mode keeps finished accounts and has a 65 s safety net |

### User-facing text

The advice depends on who can fix the problem (`AccountFailure.Audience`). Claude Code
commands never appear in manual-mode texts: they cannot change the app's manual login.

Card texts. `<cmd>` opens Claude Code with the account's config dir:
`` `CLAUDE_CONFIG_DIR=~/.claude-work claude` `` (the path is home-relative; other characters
are quoted outside the tilde), or `` `claude` `` for `~/.claude`.

| Case | Active login | Other config dir | Manual |
| --- | --- | --- | --- |
| No credential | Claude Code isn't signed in. Open Claude Code and run /login. | Not signed in. Run `<cmd>`, then /login. | Connect Claude in Settings to read usage. |
| Keychain locked | Keychain is locked. Unlock your Mac to refresh Claude usage. | Keychain is temporarily unavailable. | Same as active login |
| Credential unreadable | Claude Code's credentials can't be read. Open Claude Code and run /login. | Credentials can't be read. Run `<cmd>`, then /login. | The saved Claude tokens can't be read. Connect again in Settings. |
| Expired | Claude Code's token expired. Open Claude Code once to renew it. | Token expired. Run `<cmd>` once to renew it. | The saved Claude tokens no longer work. Connect again in Settings with new tokens. |
| HTTP 401 or 403 | Anthropic rejected Claude Code's sign-in. Open Claude Code and run /login. | Sign-in rejected. Run `<cmd>`, then /login. | Same as expired |
| Owner changed | Claude Code sign-in changed during the usage check. | Same as active login | The Claude connection changed during the usage check. |
| `.claude.json` unreadable | Could not read Claude Code's account file. Retrying at the next refresh. | Same | — |
| HTTP 429 | Anthropic is rate-limiting usage checks. (with `retryAt`) | Same | Same |
| Other HTTP status | Anthropic usage check failed (HTTP <status>). | Same | Same |
| Network failure | Could not refresh Claude usage. <reason> | Same | Same |
| Out of time | The Claude usage check timed out. | Same | Same |
| Token refresh waiting | — | — | Retrying the Claude token refresh… |
| Token refresh failed | — | — | Could not refresh the Claude tokens. <reason> |

Missing, unreadable, and rejected credentials set `needsAction`, and so do all manual
credential cases. An expired Claude Code token does not: Claude Code renews it the next time
it runs. Rate limits set `retryAt`; the UI shows the countdown.

Settings texts for automatic Connect:

| Case | Text |
| --- | --- |
| No login, unreadable item | The active-login card texts above |
| Keychain locked | Keychain access is unavailable. Unlock your Mac and try again. |
| Expired | Claude Code's token expired. Open Claude Code, then try again. |
| HTTP 401 or 403 | Anthropic rejected Claude Code's sign-in. Open Claude Code and run /login, then try again. |
| Gate closed or HTTP 429 | Anthropic is rate-limiting usage checks. Try again in <wait>. (with `retryAt`; `<wait>` is minutes or hours, rounded up) |
