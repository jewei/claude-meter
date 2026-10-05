# Cursor

Module: `Sources/ProviderCursor`. Types: `CursorProvider` (quota) and `CursorTokenHistory`
(token history). Both report one account, `AccountID.default`, named "Cursor".

Cursor's endpoints are internal to Cursor. They can change without notice.

## External contracts

### State database

| Item | Value |
| --- | --- |
| Path | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| Open | `SQLiteReader`: read-only, `readonly_shm=1`, never `immutable`, no busy wait, 1 MiB value limit |
| Table | `ItemTable(key TEXT, value TEXT or BLOB)` |
| Query | `SELECT key, CASE WHEN key = ?2 THEN length(value) > 0 ELSE value END FROM ItemTable WHERE key IN (?1, ?2, ?3, ?4) LIMIT 4` |
| Bindings, in order | `cursorAuth/accessToken`, `cursorAuth/refreshToken`, `cursorAuth/cachedEmail`, `cursorAuth/stripeMembershipType` |

The query returns only `1` or `0` for the refresh token, so its value never leaves SQLite.

Value encodings: UTF-8, ASCII UTF-16LE without a byte order mark, and UTF-16 with a byte order
mark. One pair of surrounding double quotes and outer whitespace are removed.

### Keychain

| Service | Account | Use |
| --- | --- | --- |
| `cursor-access-token` | any | The access token when the database has none. Read only. |

### Access token

The access token is a JSON Web Token. The app reads two unverified claims:

- `exp` (number, seconds): the expiry.
- `sub` (string, such as `auth0|user_123`): the user. The text after the last `|` is the user ID.

### Usage: `GetCurrentPeriodUsage`

```text
POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
Authorization: Bearer <access token>
Content-Type: application/json
Connect-Protocol-Version: 1

{}
```

Retry: never. Deadline: 20 s. Only HTTP 200 is success.

```json
{
  "billingCycleStart": "1750000000000",
  "billingCycleEnd": "1752592200000",
  "planUsage": {
    "totalSpend": 1240,
    "limit": 2000,
    "autoPercentUsed": 10.0,
    "apiPercentUsed": 100.0,
    "totalPercentUsed": 62.0
  },
  "enabled": true
}
```

| Field | Meaning |
| --- | --- |
| `billingCycleEnd` | End of the billing period: epoch seconds or milliseconds, or ISO-8601. String or number. |
| `planUsage.totalPercentUsed` | Percent used. The authoritative value. Absent means 0 when `planUsage` is present. |
| `planUsage.autoPercentUsed` | Percent used by Auto and Composer. Optional. |
| `planUsage.apiPercentUsed` | Percent used by named API models. Optional. |
| `planUsage.totalSpend` | Spend in US cents. Absent means 0 when `planUsage` is present. |
| `planUsage.limit` | Spend limit in US cents. Absent, zero, or less means no fixed limit. |
| `enabled` | `false` means that Cursor reports no usage for the account. |

The response is Connect JSON: it omits proto3 zero values and can send 64-bit integers as
strings. A present `planUsage` without `totalPercentUsed` is 0% used, so
`{"planUsage":{}}` at the start of a billing period reads as 0%, not unknown. Without
`planUsage`, the usage is unknown. A plain proto3 `enabled: false` would also be omitted, so
only an explicit `false` turns usage off. Every number can be a JSON number or a numeric
string. Other fields are ignored.

### Plan: `GetPlanInfo`

Sent only when the database has no `cursorAuth/stripeMembershipType`, after a usage request
that succeeded. Each login sends it at most once in 24 hours, also when the answer failed or
had no plan, and again after 24 hours, so a changed plan shows (rule 14). HTTP 429 holds the
login (rule 19). Same headers and body as the usage request. Deadline: 10 s.

```text
POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo
```

```json
{"planInfo": {"planName": "pro"}}
```

### Token history: usage export

```text
GET https://cursor.com/api/dashboard/export-usage-events-csv?startDate=<ms>&endDate=<ms>&strategy=tokens
Accept: text/csv
Origin: https://cursor.com
Cookie: WorkosCursorSessionToken=<user ID>%3A%3A<access token>
```

- `startDate`: local midnight six days before today, in milliseconds.
- `endDate`: now, in milliseconds.
- No `Authorization` header. The cookie exists only in this request.
- Retry: never. Deadline: 10 s. The app's 20 s history limit covers `reconcile` and the
  read. They read the credentials three times (in `reconcile`, and before and after the
  export), at most 2 s each, so 2 + 2 + 10 + 2 = 16 s leaves at least 4 s to parse.
- The HTTP client accepts at most 8 MiB. Export rows are about 90 to 150 bytes, so an export
  of roughly 56,000 to 93,000 rows or more fails as too large.

Required CSV columns (names trimmed, unique): `Date`, `Input (w/ Cache Write)`,
`Input (w/o Cache Write)`, `Cache Read`, `Output Tokens`. Other columns, such as `Model` and
`Cost`, are ignored.

```text
Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
2026-10-01T12:00:00.000Z,"unknown, model",2,10,"1,000",3,-
```

This row counts 2 + 10 + 1000 + 3 = 1015 tokens on 1 October, local time.

## Domain mapping

| Domain value | Source |
| --- | --- |
| Window `billing`, "Billing period", `.billing`, binding | `totalPercentUsed`, resets at `billingCycleEnd` |
| Window `auto`, "Auto + Composer", `.scoped`, not binding | `autoPercentUsed`, only when present |
| Window `api`, "API", `.scoped`, not binding | `apiPercentUsed`, only when present |
| `Balance(kind: .spend, unit: .currency("USD"))` | `totalSpend` / 100 with `limit` / 100, only when `planUsage` is present |
| Plan | Membership or `planName`: `free` Free, `pro` Pro, `pro_plus` or `pro+` Pro+, `ultra` Ultra, `business` Business, `team` or `teams` Teams; any other name as written |
| Owner | `.identity(sha256("cursor", sub))`, or `.credential(sha256("cursor", token))` without `sub` |

The email is never part of the reading.

## Rules

### Credentials

1. Read the database first. Read the Keychain only when the database was read and has no access
   token. A busy or unreadable database can still hold a token, and the Keychain item can
   belong to another login (the `cursor-agent` CLI), so the Keychain proves nothing then.
2. Never write, renew, or cache Cursor credentials. Never send the refresh token, and never
   read it from the Keychain or load it from the database. Diagnostics show only whether the
   database has one.
3. A missing database is not an error. The Keychain fallback runs.
4. A database that is not a regular file, or that SQLite cannot read, is unreadable. The
   Keychain is not read.
5. A locked database (`SQLITE_BUSY`, `SQLITE_LOCKED`) fails at once. It is busy, not signed out.
   The Keychain is not read.
6. A locked, refused, or failed Keychain read is a temporary failure, not a sign-out. A refused
   item asks the user to allow access in Keychain Access. A credential read (the database and
   the Keychain together) that takes more than 5 s, or 2 s for token history, is temporary
   too.
7. No access token in the database and no Keychain item means signed out. A Keychain item that
   exists but holds no usable token is unreadable, because `signInStatus` sees only the item.
8. A cancelled read does not read the Keychain.
9. Each refresh reads the credentials again, before and after its request.
10. `signInStatus` reads the database and only the attributes of the Keychain item, in the same
    order as a refresh, and sends nothing. It counts an expired token as signed in. The card
    asks the user to renew it.

### Quota

11. A token with a known `exp` at most 30 s after now is never sent. It counts as expired,
    because it would come back as HTTP 401 with a harsher message.
12. Spend and limit never give a percentage. `totalPercentUsed` is the usage.
13. A body that is not a JSON object is an unexpected response.
14. The plan request runs only when Cursor stored no plan. The provider keeps the time of each
    login's last plan request in memory. It does not send the request again for that login for
    24 hours, also after a failure or an answer without a plan, and sends it again after 24
    hours, so a changed plan shows within a day. Until then, a refresh reuses the plan that the
    same login showed, and that reuse does not move the time. A restart forgets these times: at
    the first refresh after it, a login that showed a plan reuses it and its 24 hours start, so
    a launch sends no plan request. A login without a known plan sends it at once. Its failures
    are silent and keep the plan of the same login.
15. The plan keeps the capitalization that Cursor used, except for the known names.

### Retention

16. Signed out: drop the last observation.
17. Expired token, HTTP 401, or HTTP 403: keep the last observation as stale, with an issue that
    asks the user to act, while the owner is unchanged.
18. Busy database, locked Keychain, network failure, other HTTP status, or an unexpected
    response: keep the last observation as stale while the owner is unchanged. Once the
    billing period of a kept observation ends, its window is unknown and its spend is dropped.
19. After HTTP 429 with a usable `Retry-After` on the usage or plan request, the shared
    rate-limit hold applies (`docs/architecture.md`): no request for the same login before the
    retry time, at most 1 hour after the 429, so the card's countdown is true. Another login
    sends at once. While it holds, the card shows the last reading as stale with the
    countdown. The hold comes before the expiry check, and a login that cannot be read keeps
    it, so a refresh that sends nothing never ends it early. The provider keeps each 429 in
    memory as soon as Cursor answers, before it reads the login again, so a refresh that is
    cancelled after the response still holds the login. Memory keeps one hold for each login
    (`RateLimitHolds`), so a 429 for another login never ends it: after a 429 for login A,
    then one for login B, A still waits when it signs in again before its retry time. Only
    the hold of an observed account whose token names a user (`sub`) survives a restart
    (`docs/architecture.md`). The usage request of a refresh whose plan request got the 429
    succeeded, so no account issue carries that hold: the provider keeps it in memory. A
    restart before the next refresh ends it. A refresh during the hold puts the 429 issue on
    the account, and that hold then survives a restart like a usage-request hold.
20. `"enabled": false`: drop the last observation, because it no longer describes the account.
21. If the owner after the response differs from the owner before it, discard the response.
22. `reconcile` drops the reading when the owner changed or the user signed out. It reads local
    data only.

### Token history

23. The export covers local midnight six days ago through now. Each read uses the system time
    zone of that moment for the range, the days, and the history's label, so a time zone change
    applies at the next read.
24. The four token columns are disjoint. Their sum is the row's count. Prices never count.
25. A header-only export is a real zero for the range.
26. A missing header or malformed CSV is an unexpected response for the whole export.
27. A row with the wrong column count, a bad date, or a bad number makes the history partial.
28. A row before the range start is ignored. A row after now makes the history partial.
29. Numbers accept thousands separators only in strict groups of three. An empty field is zero.
30. An export above the 8 MiB response limit fails, and the message points to the Cursor
    dashboard. The history is unknown, not partial, because no row arrives. Inside the limit,
    rows after the first 100,000 are not counted, and the history is partial.
31. A token without a `sub` user ID (the text after the last `|`, not empty), a user ID with
    characters outside `A-Z a-z 0-9 _ -`, or a token with characters outside
    `A-Z a-z 0-9 _ - .`, is an unexpected token format. No request is sent.
32. History follows the quota lifecycle and retention rule (`docs/architecture.md`). Each
    history carries the owner of the login that read it (`ProviderTokenHistory.owner`).
    `reconcile` drops a held history whose login signed out or changed, and keeps it while
    the credentials cannot be read. A failure keeps the held history, marked stale, only
    while `ProviderTokenHistory.belongs(to:)` accepts the login status after the failure. A
    login change during the export discards the result.
33. After HTTP 429 with a `Retry-After`, the shared rate-limit hold applies to the export
    (`docs/architecture.md`): no export for the same login before the retry time, at most
    1 hour after the 429. Another login exports at once. The provider keeps one hold for each
    login in memory (`RateLimitHolds`), so a 429 for another login never ends it, and a
    restart ends it.

### Messages

34. Every message says what to do, for example "Open Cursor and sign in again."
35. A decoding failure shows "Cursor returned an unexpected response. Claude Meter will try
    again soon.", never a system error.
36. Only a network that is down, or a host that cannot be found or reached, shows "Cannot reach
    Cursor. Check your internet connection." A connection that dropped had reached Cursor, so
    it shows "The Cursor request failed. Claude Meter will try again soon."
