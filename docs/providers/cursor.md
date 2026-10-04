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
| Query | `SELECT key, value FROM ItemTable WHERE key IN (?, ?, ?, ?) LIMIT 4` |
| Bindings, in order | `cursorAuth/accessToken`, `cursorAuth/refreshToken`, `cursorAuth/cachedEmail`, `cursorAuth/stripeMembershipType` |

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
| `planUsage.totalPercentUsed` | Percent used. The authoritative value. |
| `planUsage.autoPercentUsed` | Percent used by Auto and Composer. Optional. |
| `planUsage.apiPercentUsed` | Percent used by named API models. Optional. |
| `planUsage.totalSpend` | Spend in US cents. |
| `planUsage.limit` | Spend limit in US cents. Zero or less means no fixed limit. |
| `enabled` | `false` means that Cursor reports no usage for the account. |

Every number can be a JSON number or a numeric string. Other fields are ignored.

### Plan: `GetPlanInfo`

Sent only when the database has no `cursorAuth/stripeMembershipType`. Same headers and body as
the usage request. Deadline: 10 s.

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
- Retry: never. Deadline: 12 s.

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
| `Balance(kind: .spend, unit: .currency("USD"))` | `totalSpend` / 100 with `limit` / 100, only when either is present |
| Plan | Membership or `planName`: `free` Free, `pro` Pro, `pro_plus` or `pro+` Pro+, `ultra` Ultra, `business` Business, `team` or `teams` Teams; any other name as written |
| Owner | `.identity(sha256("cursor", sub))`, or `.credential(sha256("cursor", token))` without `sub` |

The email is never part of the reading.

## Rules

### Credentials

1. Read the database first. Read the Keychain only when the database was read and has no access
   token. A busy or unreadable database can still hold a token, and the Keychain item can
   belong to another login (the `cursor-agent` CLI), so the Keychain proves nothing then.
2. Never write, renew, or cache Cursor credentials. Never send the refresh token, and never
   read it from the Keychain. Diagnostics show only whether the database has one.
3. A missing database is not an error. The Keychain fallback runs.
4. A database that is not a regular file, or that SQLite cannot read, is unreadable. The
   Keychain is not read.
5. A locked database (`SQLITE_BUSY`, `SQLITE_LOCKED`) fails at once. It is busy, not signed out.
   The Keychain is not read.
6. A locked, refused, or failed Keychain read is a temporary failure, not a sign-out. A refused
   item asks the user to allow access in Keychain Access. A read that takes more than 5 s is
   temporary too.
7. No access token in the database and no Keychain item means signed out. A Keychain item that
   exists but holds no usable token is unreadable, because `signInStatus` sees only the item.
8. A cancelled read does not read the Keychain.
9. Each refresh reads the credentials again, before and after its request.
10. `signInStatus` reads the database and only the attributes of the Keychain item, in the same
    order as a refresh, and sends nothing. It counts an expired token as signed in. The card
    asks the user to renew it.

### Quota

11. A token with a known `exp` at or before now is never sent.
12. Spend and limit never give a percentage. `totalPercentUsed` is the usage.
13. A body that is not a JSON object is an unexpected response.
14. The plan request runs only when Cursor stored no plan. Its failures are silent.
15. The plan keeps the capitalization that Cursor used, except for the known names.

### Retention

16. Signed out: drop the last observation.
17. Expired token, HTTP 401, or HTTP 403: keep the last observation as stale, with an issue that
    asks the user to act, while the owner is unchanged.
18. Busy database, locked Keychain, network failure, other HTTP status, or an unexpected
    response: keep the last observation as stale while the owner is unchanged.
19. `"enabled": false`: drop the last observation, because it no longer describes the account.
20. If the owner after the response differs from the owner before it, discard the response.
21. `reconcile` drops the reading when the owner changed or the user signed out. It reads local
    data only.

### Token history

22. The export covers local midnight six days ago through now.
23. The four token columns are disjoint. Their sum is the row's count. Prices never count.
24. A header-only export is a real zero for the range.
25. A missing header or malformed CSV is an unexpected response for the whole export.
26. A row with the wrong column count, a bad date, or a bad number makes the history partial.
27. A row before the range start is ignored. A row after now makes the history partial.
28. Numbers accept thousands separators only in strict groups of three. An empty field is zero.
29. After 100,000 rows, the remaining rows are not counted, and the history is partial.
30. A token without a `sub` user ID, or with characters outside `A-Z a-z 0-9 _ - .`, is an
    unexpected token format. No request is sent.
31. A failure keeps the previous history only while the login of the last history is still
    signed in. A login change during the request rejects the result.

### Messages

32. Every message says what to do, for example "Open Cursor and sign in again."
33. A decoding failure shows "Cursor returned an unexpected response.", never a system error.
