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
- A folder can be a home when it holds `auth.json` or `config.toml`.

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

No retries. Response fields:

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

Limit 4 s, no retries. Response: `available_count` (whole number) and `credits`, an array of
rows with `status`, `title`, and `expires_at` (ISO 8601 or Unix seconds).

### App-server recovery

Command: `codex -s read-only -a never app-server`.

Executable search, in order:

1. `CODEX_CLI_PATH`, trimmed.
2. `<entry>/codex` for each `PATH` entry.
3. `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.bun/bin`, `~/.npm-global/bin`,
   `~/.volta/bin`, `/Applications/Codex.app/Contents/Resources`, `/usr/bin`.

The first executable regular file wins.

Environment: the app environment, with `CODEX_HOME` set to the home, without these variables:

```text
ANTHROPIC_API_KEY  ANTHROPIC_AUTH_TOKEN  ANTHROPIC_BASE_URL  CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_CODE_USE_BEDROCK  CLAUDE_CODE_USE_VERTEX  ANTHROPIC_BEDROCK_BASE_URL
ANTHROPIC_VERTEX_BASE_URL  OPENAI_API_KEY  OPENAI_BASE_URL  CODEX_API_KEY
CODEX_AGENT_IDENTITY  CODEX_ACCESS_TOKEN  OPENAI_FEDERATION_RULE_ID  OPENAI_IDENTITY_TOKEN_FILE
```

JSON-RPC over stdin and stdout, one compact JSON object per line, no `jsonrpc` field:

```text
→ {"id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-meter","version":"1"}}}
← {"id":1,"result":{…}}
→ {"method":"initialized","params":{}}
→ {"id":2,"method":"account/read","params":{"refreshToken":true}}
← {"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}
→ {"id":3,"method":"account/rateLimits/read","params":{}}
← {"id":3,"result":{"rateLimits":{…},"rateLimitResetCredits":{…}}}
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

6. Recovery starts only when `auth.json` is missing, has no tokens, is not valid JSON, or
   cannot be read; when the access token expires within 60 s; or when the usage request
   returns HTTP 401 or 403.
7. Network errors, timeouts, other HTTP statuses, unknown response formats, and API-key auth
   never start recovery. The original error shows.
8. Each recovery starts one child process. Each JSON-RPC step has a 5 s limit. Every path
   stops the child: TERM, then KILL after 0.25 s, then a wait until it is reaped.
9. A timeout names the step that timed out, such as `account/read`.
10. An error reply to `account/read` is ignored: account details are optional, and the rate
    limits are still read. An API-key account stops before `account/rateLimits/read`.
11. Lines that are not JSON objects, notifications, and server requests (lines with a
    `method`) are skipped while the client waits for a response.
12. A failed recovery shows both reasons: `Codex App Server failed: … Direct OAuth failed: …`.
    An API-key result shows only the API-key message.

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
21. The plan shows as `Free`, `Go`, `Plus`, `Pro 5X`, `Pro 20X`, `Team`, `Business`,
    `Enterprise`, or `Edu`, else as the plan text.

### Reset credits

22. The reset count from the usage response is the authority. Details attach only when the
    details count is equal. Only `available` rows that are not expired stay.
23. A failed details request (any status, timeout, network, or format) keeps the quota and the
    count, shows no rows, and never starts recovery. Only cancellation of the refresh stops it.
24. Codex lists only available credits in recovery rows. A row with another `status` and an
    expired row are dropped. A row without a status stays.

### Ownership and retention

25. The owner is `identity(sha256("codex", member, workspace))` when the tokens name both.
    Otherwise it is `credential(sha256(access token))`. A file without usable tokens has the
    owner `credential(sha256(file bytes))`.
26. A missing file or API-key auth is signed out. A file that cannot be read now is unknown.
27. After a direct request, the owner must be the same, or the response is discarded with
    `Codex sign-in changed or could not be verified. Refresh again.`
28. After recovery, a ChatGPT identity must stay the same. Without an identity before, the
    response is accepted with the owner that the file has after recovery, because Codex can
    rewrite the file while it renews the tokens. Without a readable file, the response is
    accepted without an owner only when the file state did not change.
29. A failed home keeps its previous observation as stale while `AccountUsage.belongs(to:)`
    accepts the current owner status. An unknown status keeps it. Otherwise the home is
    unavailable with the issue and the attempt time.
30. Observed homes with the same owner have `sharesLogin` set.

### Time and concurrency

31. One 60 s deadline covers a whole fetch, including home resolution.
32. At most three homes refresh at once. A free slot starts the next home.
33. A home that does not finish by the deadline shows
    `Codex did not answer within 60 seconds. Refresh again later.`
34. Home resolution and each `auth.json` read have a 5 s limit and run off the cooperative
    threads.
35. When the homes cannot be resolved, the fetch throws a provider error that keeps the last
    reading.

### Diagnostics

36. Diagnostics show the Codex CLI path and, for each home of the last fetch, the home path,
    what the auth file held, the source (`Usage request` or `Codex app-server`), the attempt
    time, and the result. They are in memory only.
