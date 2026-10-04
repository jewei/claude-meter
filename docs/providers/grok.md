# Grok

Module: `Sources/ProviderGrok`. Type: `GrokProvider` (quota). It reports one account,
`AccountID.default`, named "Grok". Local token history is in `Sources/ProviderGrok/History`.

The billing endpoint is internal to the Grok Build CLI. It can change without notice.

## External contracts

### Grok home

`GrokProvider.homeDirectory(environment:home:)`:

1. `GROK_HOME`, trimmed, when it is set and not blank. A leading `~` means the user's home.
   A relative value starts at the user's home: the CLI resolves it against its own working
   folder, which the app cannot know, and the app's working folder is `/`.
2. Otherwise `~/.grok`.

The app sees only the environment that it was started with. An app started from Finder or at
login does not see a `GROK_HOME` that a shell profile sets, so it reads `~/.grok` while the CLI
uses the other folder, and the card says that Grok Build is not signed in. Diagnostics show
whether the app sees `GROK_HOME`.

### Sign-in file

| Item | Value |
| --- | --- |
| Path | `<Grok home>/auth.json` |
| Read | `LocalFile.read`: regular file, symbolic links followed, at most 4 MiB, 5 s limit |

```json
{
  "https://auth.x.ai::client-uuid": {
    "key": "bearer-token",
    "auth_mode": "oidc",
    "email": "alpha@example.com",
    "expires_at": "2026-07-11T06:43:07.251431Z",
    "refresh_token": "r"
  },
  "https://accounts.x.ai/sign-in": { "key": "legacy-token" }
}
```

| Field | Use |
| --- | --- |
| Top-level key | The entry scope. |
| `key` | The bearer token, trimmed. Required. |
| `expires_at` | ISO-8601 with any fraction length, or epoch. Optional. |
| `user_id`, `account_id` | A stable account ID. Optional. |
| `email` | The stable identity when the token has no `sub` and the entry has no account ID. Trimmed and lowercased; only its SHA-256 digest is kept. Optional. |
| `auth_mode`, `refresh_token` | Ignored. |

### Billing

```text
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
Authorization: Bearer <key>
Accept: application/json
User-Agent: ClaudeMeter
```

Retry: up to 3 attempts after a transport failure (no network, a host that cannot be found or
reached, a dropped connection, a timeout) or HTTP 408, 500, 502, 503, or 504; never after 429.
A server `Retry-After` is never shortened. Deadline: 30 s for all attempts. Any 2xx status is
success.

Recorded response (grok 0.2.93):

```json
{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-04T05:57:34.172321+00:00","end":"2026-07-11T05:57:34.172321+00:00"},"creditUsagePercent":36.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":36.0}],"isUnifiedBillingUser":true,"prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","billingPeriodStart":"2026-07-04T05:57:34.172321+00:00","billingPeriodEnd":"2026-07-11T05:57:34.172321+00:00"}}
```

| Field | Meaning |
| --- | --- |
| `config.currentPeriod` | Required. Its absence is an unexpected response. |
| `currentPeriod.type` | `USAGE_PERIOD_TYPE_WEEKLY` or `USAGE_PERIOD_TYPE_MONTHLY`. |
| `currentPeriod.end` | When the period resets. |
| `config.creditUsagePercent` | Percent used. Absent means 0. |
| `config.onDemandUsed.val` | On-demand spend in US cents. Absent means 0. |
| `config.onDemandCap.val` | On-demand cap in US cents. 0 means no cap. |
| `config.prepaidBalance.val` | Prepaid balance in US cents. Absent means 0. |

The response is protobuf JSON: it omits zero values and can send 64-bit integers as strings.
Every number can be a JSON number or a numeric string. Other fields are ignored.

## Domain mapping

| Domain value | Source |
| --- | --- |
| Window `credits`, `.billing`, binding | `creditUsagePercent`, resets at `currentPeriod.end` |
| Window title | "Weekly", "Monthly", or "Credits" for any other type |
| `Balance(kind: .onDemand, unit: .currency("USD"))` | `onDemandUsed` / 100, limit `onDemandCap` / 100 when above 0 |
| `Balance(kind: .prepaid, unit: .currency("USD"))` | `prepaidBalance` / 100 |
| Owner | `.identity(sha256("grok", id))` with the token `sub`, else `user_id` or `account_id`; else `.identity(sha256("grok", "email", email))`; otherwise `.credential(sha256("grok", key))` |

Real keys are opaque `oidc-…` tokens, and the CLI writes no account ID, so the email is the
identity in practice. It survives a renewal of the key and an app restart. The email itself
never reaches a reading, a log, or the disk.

## Rules

### Sign-in

1. Order the entries: keys that start with `https://auth.x.ai`, then
   `https://accounts.x.ai/sign-in`, then all other keys. Sort the keys inside each group.
2. The first entry that has a key is the login. The clock never changes which entry that is,
   so the owner does not flip when a key expires.
3. If that entry has expired, a later entry with the same owner that has not expired is used.
   Otherwise the login is expired, and no token is sent. An entry of another login, such as
   an old legacy key, is never sent in its place.
4. An `expires_at` that does not parse means no known expiry.
5. A missing file, a missing folder, or no entry with a key means signed out.
6. A file that is not a regular file, is larger than 4 MiB, or is not a JSON object is
   unreadable. This is temporary, not a sign-out.
7. Never write, renew, or cache the sign-in. Never read `refresh_token`.
8. `signInStatus` counts an expired login as signed in. The card asks the user to renew it.

### Retention

9. Signed out: drop the last observation.
10. Expired login, HTTP 401, or HTTP 403: keep the last observation as stale, with an issue that
    asks the user to act, while the owner is unchanged.
11. Unreadable file, network failure, other HTTP status, or an unexpected response: keep the
    last observation as stale while the owner is unchanged. After HTTP 429 with a
    `Retry-After`, no request is sent before the retry time, so the card's countdown is true.
    Once the period of a kept observation ends, its window is unknown and its on-demand spend
    is dropped. The prepaid balance stays.
12. If the owner after the response differs from the owner before it, discard the response.
13. `reconcile` drops the reading when the owner changed or the user signed out. It reads local
    files only.

### Messages

14. Every message says what to do, for example "Open Grok Build and run `grok login`."
15. A decoding failure shows "Grok returned an unexpected response.", never a system error.
