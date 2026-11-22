# Antigravity

Module: `Sources/ProviderAntigravity`. Type: `AntigravityProvider` (quota). It reports one
account, `AccountID.default`, named "Antigravity". Antigravity does not report token history.

## External contracts

### Antigravity CLI

Command: `agy -p /usage --output-format json --print-timeout 30s`, run in a private temporary
working directory (`0700`) that is removed when the check finishes.

Executable search, in order:

1. `ANTIGRAVITY_CLI_PATH`, trimmed.
2. `<entry>/agy` for each `PATH` entry.
3. `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.antigravity/antigravity/bin`,
   `/Applications/Antigravity.app/Contents/Resources/app/bin`, `/usr/bin`.

The first executable regular file wins. The search has a 5 s limit.

Environment: the app environment with a clean `PATH` (the found command's folder, its
symbolic-link target's folder, the app `PATH` entries, the install folders of the search, then
`/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, without duplicates) and without variables that could
override the provider or credentials:

```text
ANTHROPIC_API_KEY  ANTHROPIC_AUTH_TOKEN  ANTHROPIC_BASE_URL  CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_CODE_USE_BEDROCK  CLAUDE_CODE_USE_VERTEX  ANTHROPIC_BEDROCK_BASE_URL
ANTHROPIC_VERTEX_BASE_URL  OPENAI_API_KEY  OPENAI_BASE_URL  CODEX_API_KEY
GEMINI_API_KEY  GOOGLE_API_KEY  GOOGLE_GENAI_USE_VERTEXAI  GOOGLE_CLOUD_PROJECT
GOOGLE_CLOUD_LOCATION
```

The child's standard input is closed immediately. The command has a 30 s deadline and a 1 MiB
output limit. Every exit path stops the child's process group: `SIGTERM`, then `SIGKILL` after
0.25 s, then a wait of at most 2 s for the reap.

### Response payload

Recorded response (`agy` 1.5.14):

```json
{
  "conversation_id": "",
  "status": "SUCCESS",
  "duration_seconds": 0,
  "num_turns": 0,
  "command": {
    "name": "usage",
    "data": {
      "groups": [
        {
          "name": "Gemini Models",
          "buckets": [
            {
              "id": "gemini-weekly",
              "name": "Weekly Limit Remaining",
              "window": "weekly",
              "remaining_fraction": 0.996646523475647,
              "reset_time": "2026-11-29T05:58:50Z"
            },
            {
              "id": "gemini-5h",
              "name": "Five Hour Limit Remaining",
              "window": "5h",
              "remaining_fraction": 0.9882627725601196,
              "reset_time": "2026-11-22T10:58:50Z"
            }
          ]
        },
        {
          "name": "Claude and GPT models",
          "buckets": [
            {
              "id": "3p-weekly",
              "name": "Weekly Limit Remaining",
              "window": "weekly",
              "remaining_fraction": 1,
              "reset_time": "2026-11-29T06:01:17Z"
            },
            {
              "id": "3p-5h",
              "name": "Five Hour Limit Remaining",
              "window": "5h",
              "remaining_fraction": 1,
              "reset_time": "2026-11-22T11:01:17Z"
            }
          ]
        },
        {
          "name": "Gemini 4 Argon",
          "buckets": [
            {
              "id": "gemini-argon-wtu-weekly",
              "name": "Gemini 4 Argon Weekly Limit",
              "window": "weekly",
              "remaining_fraction": 1,
              "reset_time": "2026-11-29T06:01:17Z"
            }
          ]
        }
      ]
    }
  }
}
```

| Field | Meaning |
| --- | --- |
| `status` | `"SUCCESS"` or `"ERROR"`. |
| `error` | Error message when `status` is `"ERROR"`. |
| `command.data.groups` | Required array of model-group quota pools. |
| `groups[].name` | Group label, such as `"Gemini Models"` or `"Claude and GPT models"`. |
| `buckets[].id` | Stable bucket ID. |
| `buckets[].window` | `"5h"` (18,000 s), `"weekly"` (604,800 s), `"daily"` / `"24h"` (86,400 s). |
| `buckets[].remaining_fraction` | Fraction left, `0...1`. Used percent is `(1 − remaining_fraction) × 100`. |
| `buckets[].reset_time` | ISO-8601 reset timestamp. Optional. |

## Domain mapping

| Domain value | Source |
| --- | --- |
| Primary binding `.session` window | The `"5h"` bucket of the primary group (`Gemini Models`, or the first group with valid buckets), titled `Gemini 5h`, duration 5 h |
| Primary binding `.weekly` window | The `"weekly"` bucket of the primary group, titled `Gemini Weekly`, duration 7 d |
| Non-binding `.scoped` windows | All buckets of secondary groups (such as `Claude & GPT 5h`, `Claude & GPT 7d`, `Gemini 4 Argon Weekly`), shown in expanded card details |
| Owner | `nil` (Antigravity's `/usage` output carries no account identity, so readings live in memory only and are never written to `readings.json`) |
| Plan | User's pick in **Settings > Data** (`AntigravitySettings.planOverride`) wins over any optional `command.data.plan` or `command.data.tier` reported by `agy` |

## Rules

1. Claude Meter never reads, writes, or refreshes Antigravity's own credentials. It only runs
   `agy -p /usage --output-format json --print-timeout 30s`.
2. Non-JSON lines printed to stdout before the JSON object are skipped.
3. When Antigravity is not signed in, `agy` prints `Authentication required` to stderr and
   waits for OAuth login. The provider watches stderr alongside stdout, stops the child
   immediately on a sign-in prompt, and reports signed out without waiting for the timeout.
4. A missing CLI or signed-out login drops the previous observation (`OwnerStatus.signedOut`).
   A timeout, launch failure, command error, or unexpected response keeps the previous
   observation as stale (`OwnerStatus.unknown`).
5. `reconcile` checks only whether `agy` is still installed and never launches a process. If
   `agy` is gone, it drops the previous observation.
6. Diagnostics show whether `ANTIGRAVITY_CLI_PATH` is set, the located `agy` path (or
   `Missing`), and the outcome of the last usage check (redacted).
