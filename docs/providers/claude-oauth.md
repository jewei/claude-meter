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
4. HTTP 200 is usage. 401 and 403 mean the token was rejected: 401 means the token is not
   valid (a manual refresh token can help), 403 that it may not read usage (a refresh cannot
   help). 429 closes the rate-limit gate. Other status codes are failures with the status in
   the text. HTTP 200 with a body that is not a JSON object is an invalid response.

### Usage response fields read

| Field | Use |
| --- | --- |
| `five_hour.utilization`, `.resets_at` | Session window |
| `seven_day.utilization`, `.resets_at` | Weekly window |
| `seven_day_opus` | Opus Weekly window, only when `utilization` has a value |
| other `seven_day_<scope>` objects | Scoped windows, only when `utilization` has a value |
| `limits[].{kind, scope.model.display_name, percent, resets_at}` | Entries with `kind: "weekly_scoped"` fill scoped windows that the flat fields do not have. An entry without a display name or a numeric `percent` is skipped. |
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
| Manual login of version 3 (app-owned) | `com.jewei.claudemeter-oauth` | `oauthManual` | Delete only: at the first fetch of each launch, release builds only |

1. `<h>` is the first 8 lowercase hex characters of the SHA-256 of the config dir's path.
   The path is absolute, has symbolic links resolved, is standardized, and has no trailing
   slash (`ConfigDirectoryScanner.canonicalPath`). Example: `/Users/me/.claude-work`
   gives `Claude Code-credentials-1e91dd84`. For a dir reached through a symbolic link, the
   hash of the path as found or configured (standardized, links kept) is tried next, because
   Claude Code may hash `CLAUDE_CONFIG_DIR` without resolving links.
2. The default dir tries the legacy item first, then its hashed item. Other dirs use only
   their hashed item.
3. Claude Code's item value is
   `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt" (epoch ms),
   "subscriptionType", "rateLimitTier"}}`. `accessToken`, `refreshToken`, and `expiresAt` are
   required.
4. The manual item value is JSON `{accessToken, refreshToken, expiresAt, connectionID}` with
   ISO-8601 dates. `expiresAt` is the real expiry or absent. Pasted tokens name no plan.
   Unknown keys are ignored.
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
- absent: no file, not a regular file, a complete file without that object, a file that
  is not one JSON object, or an `oauthAccount` that is larger than 1 MiB or not valid JSON
  (such bytes stay that way, so the file names no login);
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
2. The default name (`ClaudeAccount.name`) is `default` for `claude`, the part after
   `claude-` for `claude-<name>`, else the key. Settings (as `defaultName`) and the card show
   it capitalized, with `-` and `_` as spaces (`PresentationContext.friendlyName`): "Default",
   "Team Tools". A display name that the user sets replaces it on the card.
3. Discovery lists `~/.claude` when it exists, other `~/.claude-*` dirs that have
   `settings.json` or `projects` (sorted by name), and the configured dirs. When the home
   folder cannot be listed, or the folders cannot be listed in 5 s, discovery fails: a refresh
   keeps its reading, Settings keeps its list, and token history keeps its scan state. It
   never returns an empty list instead.
4. Two dirs with the same resolved path are one account. Two dirs with the same key keep
   one: `~/.claude` owns `claude`, then a configured dir wins, then the smaller path. Only
   the folder named `.claude` in the home folder claims the default account first, so a
   `~/.claude-*` link to it is the same account and never takes the default account. A dir
   that loses on its key does not claim its path, and a dir that loses on its path does not
   claim its key.
5. Order: the default account first, then the others by key.
6. The default account `claude` can never be disabled. Disabled accounts are listed but not
   read and have no card.
7. A configured dir that is gone or no longer has `settings.json` or `projects` is listed
   with an issue that asks the user to remove it. It is not read. It is listed only when no
   working dir has its key, so an unplugged volume never hides a working dir.
8. The active login is the legacy item when it exists, else the most recently modified
   hashed item (equal dates: the smallest service name). It belongs to the config dir whose
   services contain it. A legacy item without `~/.claude` belongs to `claude` and uses
   `~/.claude.json`. A hashed item that matches no config dir gets its own account
   `oauth-<first 8 hex of SHA-256 of the service>`, shown first.

### Automatic mode

1. Claude Meter never refreshes, writes, or deletes Claude Code's credentials.
2. A token that expires within 60 s is expired. Expired tokens are not sent.
3. The account of the active login is read on every refresh. With no active login, while
   the Keychain cannot say which login is active, or when the user turned the account of
   the active login off, that is `claude`; without a `claude` account, it is the first
   other account that can be read. The texts for the active login go only to the account of
   the active login (or to `claude` when there is none or it is unknown).
4. Every other enabled account is read when it has no previous attempt, or when its
   previous attempt started at least 290 s before this refresh started. `attemptedAt` is the
   start of the refresh that last sent the account's usage request. The 10 s below the 300 s
   timer cover the time that a refresh needs to start, which varies, so each timer tick reads
   every account. A failed request counts, so an account that always fails is also requested
   at most once in 290 s. A failure that sends no request (an expired token, a missing or
   unreadable item, an unreadable `.claude.json`, or a 429 gate that another request closed
   during this refresh) keeps the previous `attemptedAt`, so the account is read again at the
   next refresh after the user fixes it or the gate opens. Otherwise its previous value is
   returned unchanged.
5. Requests go out one at a time: the account of rule 3 first, so that a 429 never starves
   the login that Claude Code uses now (often, but not always, the menu-bar account), then
   the others in output order. The output order does not change.
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
9. When config dirs exist but the user turned every one off, the refresh throws "Every
   Claude config dir is turned off. Turn one on in Settings." and keeps no reading. With no
   config dir and no login, it throws the "isn't signed in" text of the active login.

### Manual mode

1. Manual mode has one account, `claude` (`default`).
2. Connect checks the new tokens with a usage request, then saves them. A token that
   expires within 60 s is refreshed first. When the request gets HTTP 401 and no refresh
   happened yet (for example, no expiry was entered), the refresh token is tried once and
   the request is sent again. A failure leaves the old manual login unchanged.
3. A refresh spends the pasted refresh token, so Connect never sends one while the 429 gate
   is closed; it says when to try again. The tokens that a Connect refresh got stay in
   memory, by pasted refresh token, so a retry with the same pasted tokens uses them and
   sends no new token request, also after a Connect of other tokens. Connect looks for them
   when it starts, and again just before it would refresh, so a Connect that overlaps the one
   that got them uses them too; when they expire within 60 s, it refreshes them with their own
   refresh token, never with the spent pasted one. A Connect sends no refresh token after a
   Connect was stored or a Disconnect started since it began, because those forget the tokens;
   it says that the connection changed. A newer Connect, or a cancel, does not stop its
   refresh: a newer Connect of the same pasted tokens can use the tokens that it gets. The last
   4 pasted refresh tokens keep theirs; a newer one forgets the oldest. HTTP 401 or 403 for
   their access token, `invalid_grant` for their refresh token, a stored Connect, Disconnect,
   or quitting the app forgets them. A rejection of other tokens, such as the spent pasted
   ones, keeps them.
4. A stored token is refreshed when it expires within 60 s, and once after HTTP 401. HTTP
   403 is not refreshed: a refresh does not change the scopes. Callers with the same refresh
   token share one token request, and each caller keeps the connection ID of its own login.
5. Disconnect wins. From the moment it starts there is no manual login: a fetch reports
   "not connected" without a Keychain read, and nothing that started earlier (a fetch, a
   token refresh, or a Connect) can send the old tokens again, save, or change anything.
   After HTTP 401, a fetch checks that its login is still the stored one before the token
   refresh and again before the second request, so a Disconnect or a Connect during the
   first request stops it with "connection changed". A rotation that arrives after a
   Disconnect is forgotten, and a fetch checks its login again after the save of a
   rotation, so a Disconnect during that save also sends nothing. A Connect that started
   before a Disconnect, or before a newer Connect, stores nothing and says that the
   connection changed. `cancelManualConnect()` does the same for running Connects and keeps
   the stored login.
6. Connect asks its caller whether it is still wanted (`isWanted`) twice: before it takes
   the write lock, and again after the save, under the lock. It checks its ticket each time,
   and again when it has the lock. Under the lock, before the save, it reads the old item. A
   Connect that is abandoned during the save writes the old item back, or deletes the new one
   when there was none, and says that the connection changed. When the old item cannot be
   read, Connect fails before it writes. Until a Connect is stored, its tokens are not the
   login, even when a fetch reads them from the Keychain: the fetch uses the old login from
   memory, or says that the connection changed, so it never shows their quota or refreshes
   them. This also holds after the Connect was abandoned or its save failed, until the next
   stored Connect or Disconnect, or until the app quits: only memory knows these tokens. So
   the item is repaired in the same launch. When a fetch reads such tokens and has the old
   login in memory, it writes the old login back over them, after the writes before it, unless
   a write-back landed meanwhile. One repair runs at a time; a repair that fails is tried again
   at the next fetch. When the app quits before a repair, or has no old login in memory, the
   tokens stay in the item and are the login after the next launch.
7. `ClaudeSettingsModel` runs one attempt at a time; a newer attempt overtakes an older one.
   Its `isWanted` is true while the Connect is the newest attempt, the user did not abandon
   it (Cancel, or Claude turned off), and Claude is on. A manual Connect that the provider
   stored is applied, even when it was abandoned after the save. An automatic Connect stores
   nothing in the provider, so the model decides after the check: it deletes the manual item
   first, then changes the setting and asks for a refresh in one turn. The model calls
   Disconnect in every mode and never abandons it. A Disconnect whose delete fails still
   turns the connection off; for a manual connection it also says that the tokens could not
   be deleted. Each reload (at launch, and each time the Data page of Settings shows) deletes
   a manual item that no manual connection uses, while no attempt runs. When no manual item
   is left, that message goes away.
8. Keychain writes of the manual item run one at a time, in order, on a private queue,
   never on the shared `BlockingIO` threads. Connect reads the old item on the same queue,
   after the writes before it. A write that times out before it starts is skipped, so it
   cannot land later: the write is marked as abandoned before its caller hears of the
   timeout. A Keychain call that already runs cannot be stopped. A save of rotated tokens
   finishes even when the refresh that got them was cancelled.
9. A Connect whose save fails leaves the old login as it was, and a rotation of the old
   login that arrives meanwhile is still saved. When the save times out while its Keychain
   call runs, the call can still land, so Connect queues a write-back of the old item behind
   it. The write-back has no deadline and is never skipped. When a write-back fails, the
   repair of rule 6 writes the old login back.
10. A refresh token rejected with `invalid_grant` is not sent again. When the server also
    rejects the refreshed token (HTTP 401 or 403), or a 401 cannot be refreshed, the
    connection gets no more requests. Both marks last until the next Connect or app launch,
    and the card asks for a new Connect. After a temporary failure, refreshes wait 5
    minutes, doubling up to 6 hours. The fetch that failed shows the reason on the card
    ("Could not refresh the Claude tokens. <reason>"), and the log keeps it; while the
    refresh waits, the card says "Retrying the Claude token refresh…".
11. Manual tokens must come from a separate login, never from Claude Code's own Keychain
    item. A refresh rotates the refresh token, so a copy of Claude Code's token would sign
    Claude Code out at its next renewal. Settings must say this next to the token fields.

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
   invalid or expired record is removed, and so is a record longer than 24 hours, or one
   whose deadline is more than 24 hours and 5 minutes away (the clock moved back). The 5
   minutes let a block at the cap survive a small time correction.

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
4. A flat `seven_day_<scope>` field with a value wins over `limits[]`. A key whose scope has
   no letter or digit, such as `seven_day_`, is ignored. A `limits[]` key is
   `seven_day_` plus the first word of the model name that is not "Claude", lowercased. The
   first entry per key wins.
5. Extra usage: amount and limit are minor units divided by `10^decimal_places` (default 2,
   0 through 18) as exact decimals. The percent is `utilization`, else used over limit. The
   currency is upper case, `USD` when missing or empty. `is_enabled: false` is paused.
6. Usage-limit resets: `eligible: false` with `ineligible_reason: "surface"` is unknown (nil).
   Any other `eligible: false` is zero resets. Keep grants with `resets_left > 0` that have
   started and not ended. An empty label is "Usage reset". At most 99 resets count in
   total, over all grants; grants after the limit are not read. Without `cedar_ember`, with
   `grants` missing, or with a grant that is not an object, the count is unknown.
7. The plan is from the credential's `subscriptionType` and `rateLimitTier`, else the
   `.claude.json` tier: "Max 20x", "Max 5x", "Max", "Pro", "Team", "Enterprise", "Free".
   Manual tokens name no plan. A plan badge that the user picks in Settings wins over the
   reported plan: Claude Code keeps the plan of the last sign-in, so after a plan change
   the reported plan stays old until the next `/login`.

### Limits

| Work | Limit |
| --- | --- |
| Config dir discovery | 5 s |
| One Keychain or file read | 5 s (`BlockingIO`) |
| One write of the manual item, or the read of the old item before a Connect saves | 5 s, on the vault's write queue; the write-back after a save that timed out has none |
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
| Keychain did not answer (locked, timed out, too many reads waiting, or an item that needs approval) | The Keychain did not answer. If your Mac is locked, unlock it. Retrying at the next refresh. | Keychain is temporarily unavailable. | Same as active login |
| Credential unreadable | Claude Code's credentials can't be read. Open Claude Code and run /login. | Credentials can't be read. Run `<cmd>`, then /login. | The saved Claude tokens can't be read. Connect again in Settings. |
| Expired | Claude Code's token expired. Open Claude Code once to renew it. | Token expired. Run `<cmd>` once to renew it. | The saved Claude tokens no longer work. Connect again in Settings with new tokens. |
| HTTP 401 or 403 | Anthropic rejected Claude Code's sign-in. Open Claude Code and run /login. | Sign-in rejected. Run `<cmd>`, then /login. | Same as expired |
| Owner changed | Claude Code sign-in changed during the usage check. | Same as active login | The Claude connection changed during the usage check. |
| `.claude.json` unreadable | Could not read Claude Code's account file. Retrying at the next refresh. | Same | — |
| HTTP 429 | Anthropic is rate-limiting usage checks. (with `retryAt`) | Same | Same |
| Other HTTP status | Anthropic usage check failed (HTTP <status>). | Same | Same |
| Invalid response | Claude returned an invalid usage response. | Same | Same |
| Network failure | Could not refresh Claude usage. <reason> | Same | Same |
| Out of time | The Claude usage check timed out. | Same | Same |
| Token refresh waiting | — | — | Retrying the Claude token refresh… |
| Token refresh failed | — | — | Could not refresh the Claude tokens. <reason> |

Missing, unreadable, and rejected credentials set `needsAction`, and so do all manual
credential cases. An expired Claude Code token does not: Claude Code renews it the next time
it runs. Rate limits set `retryAt`; the UI shows the countdown.

Texts of a refresh that fails as a whole (`ProviderError`). The app keeps the last reading,
marked stale, unless the last column says no.

| Case | Text | Keeps the reading |
| --- | --- | --- |
| Claude not connected | Connect Claude in Settings to read usage. | No |
| Gate closed | Anthropic is rate-limiting usage checks. (with `retryAt`) | Yes |
| Config dirs not listed: the home folder cannot be listed, or 5 s passed | Could not read the Claude config folders. <reason> | Yes |
| Keychain did not answer, no account left | The Keychain did not answer. If your Mac is locked, unlock it. Retrying at the next refresh. | Yes |
| Every config dir turned off | Every Claude config dir is turned off. Turn one on in Settings. | No |
| No config dir and no login | Claude Code isn't signed in. Open Claude Code and run /login. | No |
| Whole refresh out of time (65 s automatic, 60 s manual) | Could not refresh Claude usage. Timed out after <limit>. | Yes |

Settings texts for automatic Connect:

| Case | Text |
| --- | --- |
| No login, unreadable item | The active-login card texts above |
| Keychain did not answer | The Keychain did not answer. If your Mac is locked, unlock it, then try again. |
| Expired | Claude Code's token expired. Open Claude Code, then try again. |
| HTTP 401 or 403 | Anthropic rejected Claude Code's sign-in. Open Claude Code and run /login, then try again. |
| Gate closed or HTTP 429 | Anthropic is rate-limiting usage checks. Try again in <wait>. (with `retryAt`; `<wait>` is minutes or hours, rounded up) |
| Network failure | Could not refresh Claude usage. <reason> |
| Other HTTP status | Anthropic usage check failed (HTTP <status>). |
| Invalid response | Claude returned an invalid usage response. |
| Usage check out of time (60 s) | Could not check Claude usage. Timed out after 60s. |

Settings texts for manual Connect:

| Case | Text |
| --- | --- |
| No access token | Enter an access token. |
| Expired, no refresh token | The access token has expired. Enter a new one, or add a refresh token. |
| Refresh token rejected (`invalid_grant`) | Anthropic rejected the refresh token. Enter new tokens. |
| Refresh failed (temporary) | Could not refresh the tokens. <reason> Try again shortly. |
| HTTP 401 or 403 | Anthropic rejected these tokens. Check them and try again. |
| Gate closed or HTTP 429, network failure, other HTTP status, invalid response, out of time | The same texts as automatic Connect |
| Disconnect or newer Connect meanwhile | The Claude connection changed while the tokens were checked. Try again. |
| Save failed, or the old item cannot be read before the save | Could not save the tokens in the Keychain. <reason> Try again. |

Settings texts of `ClaudeSettingsModel`, for both Connects and Disconnect:

| Case | Text |
| --- | --- |
| Connect stored | Connected. |
| Claude turned off before the Connect was stored | Claude was turned off, so the connection was not saved. |
| Cancel, or a newer attempt | No text |
| Disconnect of a manual connection whose delete failed | Disconnected, but the saved Claude tokens could not be deleted. Claude Meter will try again. |
