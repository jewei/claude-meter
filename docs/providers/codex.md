# Codex provider

`ProviderCodex` reads Codex subscription quota for each Codex home. Source:
`Sources/ProviderCodex`. Tests: `Tests/ProviderCodexTests`.

## External contracts

### Homes

- A Codex home is a Codex config directory (`CODEX_HOME`). Each home is one account.
- The implicit home is `$CODEX_HOME` when the variable is not empty after trimming, else
  `~/.codex`. Extra homes come from `CodexConfiguration.extraHomes`.
- The account ID is the canonical home path: standardized, with symbolic links resolved.
- The default account name is `Codex` for the implicit home, else the folder name.
- A folder can be a home when it holds `auth.json` or `config.toml`. A configured home whose
  folder does not exist has no login (rule 26).

### `auth.json`

Path: `<home>/auth.json`. Codex owns the file. The app reads it and never writes it. A read
opens without blocking, accepts only a regular file, and stops at 4 MiB.

| Field | Use |
| --- | --- |
| `auth_mode` | Auth mode (see rule 3) |
| `OPENAI_API_KEY` | API-key auth when `auth_mode` is not ChatGPT |
| `tokens.access_token`, or `tokens.accessToken` | Bearer token |
| `tokens.id_token`, or `tokens.idToken` | Owner claims |
| `tokens.account_id`, or `tokens.accountId` | `ChatGPT-Account-Id` header and owner workspace |
| `tokens.refresh_token` | Never read |

### JWT claims (not verified)

| Claim | Token | Use |
| --- | --- | --- |
| `exp` | access | Renewal hint (rule 5) |
| `https://api.openai.com/auth` → `chatgpt_account_id` | ID, then access | Owner workspace |
| `chatgpt_account_id` | ID, then access | Owner workspace, fallback |
| `https://api.openai.com/auth` → `chatgpt_user_id` | ID, then access | Owner member |
| `sub` | ID, then access | Owner member, fallback |

Tokens larger than 64 KiB are not parsed.

### Usage request

```text
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access token>
Accept: application/json
User-Agent: ClaudeMeter
ChatGPT-Account-Id: <account ID>      (only when not empty)
```

No retries. Limit 15 s. HTTP 401 and 403 start recovery (rule 6). HTTP 429 holds the next
requests (rule 31). Response fields:

| Path | Type | Strict |
| --- | --- | --- |
| `rate_limit.primary_window`, `rate_limit.secondary_window` | object or null | yes |
| `…window.used_percent` | number or numeric string, percent used | yes |
| `…window.reset_at` | number or numeric string, Unix seconds | yes |
| `…window.limit_window_seconds` | number or numeric string | yes |
| `plan_type` | string | no |
| `credits.unlimited` | bool | no |
| `credits.balance` | numeric string or number | no |
| `rate_limit_reset_credits.available_count` | whole number | no |

### Reset-credit details request

Sent only when `available_count` is more than 0.

```text
GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
Authorization, Accept, User-Agent, ChatGPT-Account-Id: as for the usage request
OpenAI-Beta: codex-1
originator: Codex Desktop
```

Limit 4 s, no retries. HTTP 429 holds the next requests of the login (rule 23). Response:
`available_count` (whole number) and `credits`, an array of rows with `status`, `title`, and
`expires_at` (ISO 8601 or Unix seconds).

### App-server recovery

Command: `codex -s read-only -a never app-server`.

Executable search, in order:

1. `CODEX_CLI_PATH`, trimmed.
2. `<entry>/codex` for each `PATH` entry.
3. `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.bun/bin`, `~/.npm-global/bin`,
   `~/.volta/bin`, `/Applications/Codex.app/Contents/Resources`, `/usr/bin`.

The first executable regular file wins. The search has a 5 s limit.

Environment: the app environment, with `CODEX_HOME` set to the home and a new `PATH` (below),
without these variables:

```text
ANTHROPIC_API_KEY  ANTHROPIC_AUTH_TOKEN  ANTHROPIC_BASE_URL  CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_CODE_USE_BEDROCK  CLAUDE_CODE_USE_VERTEX  ANTHROPIC_BEDROCK_BASE_URL
ANTHROPIC_VERTEX_BASE_URL  OPENAI_API_KEY  OPENAI_BASE_URL  CODEX_API_KEY
CODEX_AGENT_IDENTITY  CODEX_ACCESS_TOKEN  OPENAI_FEDERATION_RULE_ID  OPENAI_IDENTITY_TOKEN_FILE
```

An npm or bun install of Codex is a script that starts with `#!/usr/bin/env node`, and an app
started from the Finder has `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. So the child `PATH` is, in
order and without duplicates: the folder of the found command, the folder of its symbolic-link
target, `<prefix>/bin` when the target is in `<prefix>/lib/node_modules/`, the app `PATH`
entries, the install folders of the search, then `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`.

JSON-RPC over stdin and stdout, one compact JSON object per line, no `jsonrpc` field:

```text
→ {"id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-meter","version":"1"}}}
← {"id":1,"result":{…}}
→ {"method":"initialized","params":{}}
→ {"id":2,"method":"account/read","params":{"refreshToken":true}}
← {"id":2,"result":{"account":{"type":"chatgpt","email":"…","planType":"plus"},…}}
→ {"id":3,"method":"account/rateLimits/read","params":{}}
← {"id":3,"result":{"rateLimits":{…},"rateLimitsByLimitId":{…},"rateLimitResetCredits":{…}}}
```

The shapes are the upstream protocol types in `openai/codex`
(`codex-rs/app-server-protocol`, `GetAccountResponse` and `GetAccountRateLimitsResponse`).

| Path in the `account/rateLimits/read` result | Use |
| --- | --- |
| `rateLimits` | Required object: the snapshot of the `codex` limit |
| `rateLimits.primary`, `rateLimits.secondary` | Positional windows |
| `rateLimits.credits` | `unlimited` and `balance` |
| `rateLimits.planType` (or `plan_type`) | Plan |
| `rateLimitsByLimitId` (or `rate_limits_by_limit_id`) | Map of limit ID to a snapshot with its own `primary` and `secondary`; fills empty slots (rule 16) |
| `rateLimitResetCredits` | `availableCount` and `credits` rows with `status`, `title`, and `expiresAt` (Unix seconds) |

A window has `usedPercent` (required), `windowDurationMins`, and `resetsAt` (Unix seconds).
`account/read` returns `account`: `{"type":"chatgpt","email":…,"planType":…}`,
`{"type":"apiKey"}`, another type, or `null` when Codex has no login. An error reply is
`{"id":N,"error":{"message":"…"}}`.

The app never calls an endpoint or method that uses a reset credit or renews a token itself.

## Behavior rules

### Credentials

1. A normal refresh reads `auth.json` once for the credentials and the owner, sends one usage
   request, and reads the owner once more after the response. No process starts.
2. `reconcile` reads `auth.json` once for each home that has an observation, to drop an
   observation whose login changed before the slow request starts.
3. One auth-mode rule reads `auth_mode` and the app-server account `type`. The text is trimmed
   and compared without case. `chatgpt`, `chat_gpt`, and `chatgptAuthTokens` are ChatGPT.
   `api`, `apikey`, `api_key`, and `openai_api_key` are API key.
4. API-key mode wins over stored tokens. ChatGPT mode wins over a stored `OPENAI_API_KEY`.
   Without ChatGPT mode, a stored `OPENAI_API_KEY` means API-key auth. API-key auth has no
   subscription quota: no request is sent and recovery does not start.
5. When the access token `exp` is a number in range and at most 60 s after now, the usage
   request is skipped and recovery starts. An unknown or malformed `exp` sends the request.

### Recovery

6. Recovery starts only when `auth.json` is missing, has no tokens, or is not valid JSON;
   when the access token expires within 60 s; or when the usage request returns HTTP 401 or
   403. A home folder that does not exist starts no recovery: Codex has no login there, and
   the child could create files in it. A file that cannot be read now, and a read that does
   not finish in time, start no recovery and send nothing: the file names no owner, so the
   answer could never be verified (rule 28). The status is unknown (rule 26).
7. Network errors, timeouts, other HTTP statuses, unknown response formats, and API-key auth
   never start recovery. The original error shows. A redirect to another site and a response
   over the size limit are unknown response formats, not network errors: the server answered.
8. Each recovery starts one child process. The executable search and `initialize` have a 5 s
   limit each. `account/read` (Codex renews the token there) and `account/rateLimits/read`
   reach the network and have a 10 s limit each. Every path stops the child: TERM, then KILL
   after 0.25 s, then a wait of at most 2 s for the reap. A child that is not reaped by then
   is logged and left running, so recovery ends within 32.25 s (rule 32).
9. A timeout names the step that timed out, such as `account/read`. A child that stops
   before it answers `initialize` asks the user to update Codex, because a Codex without
   `app-server`, or one that cannot run, ends at once. A child that stops later asks the
   user to check that `codex` runs in Terminal.
10. An error reply to `account/read` is ignored: account details are optional, and the rate
    limits are still read. An API-key account, and `"account": null` (no login), stop before
    `account/rateLimits/read`. An error reply to `account/rateLimits/read` reads
    `Codex CLI request failed: <text>. Refresh again later.`
11. Lines that are not JSON objects, notifications, and server requests (lines with a
    `method`) are skipped while the client waits for a response.
12. A failed recovery shows one sentence with one action. It is the recovery reason when the
    home has no auth file (only Codex can read that login), when only the user can fix the
    recovery (such as a missing CLI), or when Codex answered without usage. Otherwise it is
    the reason that sent the login to recovery (such as "login required"), because that names
    the problem and its fix. Diagnostics show both reasons. An API-key result, and
    `"account": null`, show only their own message. A search for the executable that does not
    finish in 5 s has its own message; it never says "launch".

### Quota

13. Usage numbers are decoded as numbers, and numeric strings are accepted.
14. A present usage window with a value of the wrong type fails the usage request. Malformed
    plan, credits, or reset metadata is dropped, and the windows stay.
15. A reading needs a window or credits. Plan or reset metadata alone is "no usage windows".
16. Positional `primary` and `secondary` windows win. Keyed snapshots fill only an empty slot:
    of their `primary` and `secondary` windows, the most used session window (rule 17) fills
    `primary`, and the most used weekly window fills `secondary`. A tie keeps the smallest
    limit ID. A malformed keyed window drops only itself. An app-server window without a
    numeric `usedPercent` is not a window. A value that is not a snapshot, or a map in another
    place, never becomes a window.
17. A window of at most 24 hours is a session window. A longer window is weekly. Without a
    duration, `primary` is session and `secondary` is weekly.
18. Window titles are `Session` and `Weekly`, from the kind, the same as Claude. A limit ID
    is never a title.
19. A percent above 100 shows as 100 and over the limit. Dates outside 1970 to 3000 are
    unknown.
20. Credits become a `credits` balance. Unlimited credits have no amount.
21. The plan shows as `Free`, `Go`, `Plus`, `Pro 5X` (`prolite`), `Pro 20X` (`pro`), `Pro Max`
    (`promax`), `Team`, `Business` (`business` and both `self_serve_business_*`), `Enterprise`
    (`enterprise`, `ent26`, and both `enterprise_cbp_*`), `Edu`, `Edu Plus`, or `Edu Pro`,
    else as the plan text. `unknown` shows no plan.

### Reset credits

22. The reset count from the usage response is the authority. Details attach only when the
    details count is equal. Only `available` rows that are not expired stay.
23. A failed details request (any status, timeout, network, or format) keeps the quota and the
    count, shows no rows, and never starts recovery. Only cancellation of the refresh stops it.
    After HTTP 429 with a usable `Retry-After`, the hold of rule 31 starts for the login. The
    usage request of that refresh succeeded, so no account issue carries the hold: the
    provider keeps it in memory, and a restart ends it.
24. Codex lists only available credits in recovery rows. A row with another `status` and an
    expired row are dropped. A row without a status stays.

### Ownership and retention

25. The owner is `identity(sha256("codex", member, workspace))` when the tokens name both.
    Otherwise it is `credential(sha256(access token))`. Valid JSON without usable tokens has
    the owner `credential(sha256(file bytes))`. A login without `auth.json` (Codex can keep it
    in the keyring) has the owner `credential(sha256("codex-app-server", email))` from the
    ChatGPT email that `account/read` reports. A file that is not JSON names no owner.
26. The owner status from the file: tokens are signed in with their owner. API-key auth and
    a home folder that does not exist are signed out. A missing file is unknown (only Codex
    knows a keyring login). A file that is not JSON is unknown (Codex can be rewriting it). A
    file that cannot be read now is unknown. A read that times out or finds no free
    blocking-read thread is temporary: `Reading the Codex auth file took too long. Claude Meter
    will try again soon.` A path that is not a regular file, such as a folder, and a file over
    4 MiB say ``Codex auth file is not a normal file, or is larger than 4 MiB. Remove it, then
    run `codex login`.`` A refused read, and any other read failure, says `Could not read Codex
    auth file. Check that your user can read it.` Only the user can fix these two, so they ask
    the user to act. None of these sends a request or starts recovery (rule 6), so the home
    keeps its previous observation as stale.
27. After a direct request, the owner must be the same, or the response is discarded with
    `Codex sign-in changed or could not be verified. Refresh again.` A failure belongs to the
    login that sent the request: when the status after it (rule 29) names another signed-in
    login, the failure shows the same text and that login is its owner, so a 429 of the old
    login never holds the new one. A login that cannot be read after it proves nothing, and the
    failure stays.
28. After recovery, a ChatGPT identity must stay the same. Without an identity before, the
    response is accepted with the owner that the file has after recovery, because Codex can
    rewrite the file while it renews the tokens. Without a file before and after, the response
    is accepted with the owner from `account/read`. Every other case, including a file that
    cannot be read or parsed after recovery, names no owner, and the response is discarded.
    An observation always has an owner.
29. A failed home keeps its previous observation as stale while `AccountUsage.belongs(to:)`
    accepts the current owner status. An unknown status keeps it. Otherwise the home is
    unavailable with the issue and the attempt time. The status after a failure: API-key auth,
    and `"account": null` from Codex, are signed out whatever the file says. Without a file,
    the account from `account/read` decides, no Codex CLI is signed out, and otherwise the
    status is unknown. With a file, rule 26 decides.
30. Observed homes with the same owner have `sharesLogin` set.
31. After HTTP 429 with a usable `Retry-After`, the shared rate-limit hold applies
    (`docs/architecture.md`): no usage request and no recovery for the same login before the
    retry time, at most 1 hour after the 429, so the card's countdown is true. The limit
    belongs to the login, so every home with that login waits: each fetch collects the holds
    of all homes by owner. A held home keeps its previous observation as stale with the 429
    issue, or stays unavailable with its owner, so a first 429 holds too. Another login sends
    at once. A home that sends nothing for another reason, such as one that did not finish by
    the fetch deadline, keeps the hold. The card says
    `Codex limited the number of requests. Claude Meter will try again later.` Other HTTP
    statuses, and a 429 without a usable `Retry-After`, show no countdown, because nothing
    waits for them.

### Time and concurrency

32. One 60 s deadline covers a whole fetch, including home resolution. The slowest path of a
    home that starts at once fits inside it (`CodexLimits.worstCaseFetch`): home resolution
    (5 s), the `auth.json` read before the request (3 s), a usage request that ends in HTTP 401
    or 403 (15 s), recovery (32.25 s), and the read after it (3 s), 58.25 s in total.
33. At most three homes refresh at once. A free slot starts the next home.
34. A home that does not finish by the deadline shows
    `Codex did not answer in time. Refresh again later.` The text names no number, because a
    home that started late had less time.
35. Home resolution has a 5 s limit and each `auth.json` read a 3 s limit. Both run off the
    cooperative threads.
36. When the homes cannot be resolved, the fetch throws a provider error that keeps the last
    reading.

### Diagnostics

37. Diagnostics show the Codex CLI path and, for each home of the last fetch, the home path,
    what the auth file held, the source (`Usage request` or `Codex app-server`), the attempt
    time, the result, and both reasons of a failed recovery. When the child could not start,
    stopped, or sent a line that cannot be read, the reasons end with `Details:` and the
    launch error or the last line that the child wrote to standard error, redacted. The card
    never shows it. Diagnostics are in memory only.
