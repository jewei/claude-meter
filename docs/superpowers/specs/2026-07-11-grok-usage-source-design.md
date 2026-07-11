# Grok Usage Source — Design

**Date:** 2026-07-11
**Status:** Approved

## Goal

Add a Grok usage meter to Claude Meter, alongside the existing Codex and Cursor
provider cards. Reads the weekly Grok Build (xAI CLI) credit usage for the
signed-in subscriber and shows it as an opt-in popover card.

## Data source (verified live 2026-07-11, grok 0.2.93)

- **Credentials:** `~/.grok/auth.json` (override root via `GROK_HOME`), written
  by the official Grok Build CLI. Top-level keys are OIDC scope identifiers;
  prefer the `https://auth.x.ai::<client-id>` entry (SuperGrok/X Premium OIDC),
  fall back to `https://accounts.x.ai/sign-in` (legacy). Per-entry fields used:
  `key` (bearer JWT, ~6 h TTL), `email`, `expires_at` (ISO 8601).
  The CLI owns token refresh — Claude Meter never refreshes and never writes.
  An expired token is never sent; it maps to login-required.
- **Endpoint:** `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
  with `Authorization: Bearer <key>` and `x-grok-client-version` headers.
  This is the same upstream call the CLI's own `/usage` billing extension makes.
  Unofficial — may break without notice (same caveat as Cursor's
  `api2.cursor.sh`).
- **Response shape** (live sample):

  ```json
  {"config":{
    "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
      "start":"2026-07-04T05:57:34.172321+00:00",
      "end":"2026-07-11T05:57:34.172321+00:00"},
    "creditUsagePercent":36.0,
    "onDemandCap":{"val":0},
    "onDemandUsed":{"val":0},
    "productUsage":[{"product":"GrokBuild","usagePercent":36.0}],
    "isUnifiedBillingUser":true,
    "prepaidBalance":{"val":0},
    "billingPeriodStart":"2026-07-04T05:57:34.172321+00:00",
    "billingPeriodEnd":"2026-07-11T05:57:34.172321+00:00"}}
  ```

- **Mapping:**
  - `usedPercent` = `config.creditUsagePercent`. Proto3 omits zero values, so
    an absent `creditUsagePercent` inside a present `currentPeriod` means 0 —
    decode as 0, not missing (CodexBar-documented gotcha).
  - `resetsAt` = `currentPeriod.end`.
  - Window label from `currentPeriod.type`: `USAGE_PERIOD_TYPE_WEEKLY` →
    "Weekly", `…_MONTHLY` → "Monthly", else "Credits".
  - Monetary `{ "val": <int> }` wrappers are minor units (cents). Surface
    `onDemandUsed`/`onDemandCap`/`prepaidBalance` when non-zero.
  - `accountEmail` from `auth.json`.

## Rejected alternatives

- **ACP JSON-RPC** (`grok agent stdio`, `x.ai/billing`) — CodexBar's approach,
  built before the REST endpoint existed; subprocess per poll plus JSON-RPC
  `\/`-escaping quirks. Superseded by direct REST.
- **grok.com gRPC-web + browser cookies** — same browser-cookie pattern this
  project removed with the claude.ai source. Not acceptable.
- **Local session signals** (`~/.grok/sessions/*/signals.json`) — informational
  only, no quota data. Skipped.

## Architecture

Mirrors the Codex provider (simpler: one source, no mode picker).

### Core — `ClaudeMeterCore` (no AppKit/SwiftUI)

- **`GrokAuth.swift`** — `GrokAuthStore.load(root:now:)` parses `auth.json`,
  selects entry (auth.x.ai preferred), returns
  `GrokCredentials { bearer, email, expiresAt }` or a typed failure
  (`missing` / `loginRequired` when expired / `unreadable`).
- **`GrokUsage.swift`** — public `GrokUsage` model (`usedPercent`,
  `windowLabel`, `resetsAt`, `onDemandUsedCents`, `onDemandCapCents`,
  `prepaidBalanceCents`, `accountEmail`, `updatedAt`) plus internal
  `GrokBillingResponse: Decodable` and the mapping function.
  `energyLeftPercent` mirrors `CodexLimitWindow` (clamped `100 − used`).
- **`GrokUsageProvider.swift`** — `fetchUsage(now:) async throws -> GrokUsage`
  via injected `HTTPTransport` (default `ProviderHTTPClient.shared`), retry
  `.transient` (idempotent GET). 401/403 → `GrokUsageError.loginRequired`
  ("Open Grok Build and run /login" guidance); other non-2xx →
  `.httpError(code)`. `isAvailable()` = credentials load succeeds.

### App target

- **`AppState`** — `@Published grokUsage: GrokUsage?`, `grokError: String?`,
  `grokLastPolledAt: Date?`; `grokIsStale` via
  `AppGroupConfig.isSnapshotStale`; `pollGrok(generation:)` added to the
  parallel poll group, gated on `AppSettings.grokSourceEnabled`
  (UserDefaults key `grokSourceEnabled`, default **false**);
  `setGrokSourceEnabled` + `clearGrokState` mirror Codex; `grokError` runs
  through `DiagnosticsSanitizer.sanitize` (JWT/email already covered).
- **`PopoverView`** — Grok card mirroring the Codex card: energy ring/bar,
  window label + reset countdown, account email, on-demand row only when
  `onDemandUsedCents > 0`. Errors surface on the card like `cursorError`.
- **`SettingsView`** — Data tab toggle card ("Grok — reads Grok Build CLI
  sign-in; unofficial endpoint" disclaimer). No mode picker.
- **`DiagnosticsView`** — Grok section (sanitized usage/error/last-poll).

### Exclusions (parity with Codex/Cursor)

Menu bar stays Claude-only. No widget, no notifications, no self-refresh of
tokens, no subscription-tier display (not in this endpoint's response).

### `project.pbxproj`

Hand-maintained — three new Core files need no pbxproj entries (SwiftPM), but
any new app-target file would. Current design adds **no** new app-target
files (edits only), so no pbxproj changes.

## Error handling

| Condition | Behavior |
| --- | --- |
| `auth.json` missing / no usable entry | Card error: "Grok Build CLI not signed in" |
| Token expired (`expires_at` past) | login-required error, token never sent |
| HTTP 401/403 | login-required error |
| Other HTTP / decode failure | sanitized error string on card |
| Any Grok failure | never affects Claude/Codex/Cursor polls (independent task) |

## Testing

`ClaudeMeterCore` tests, stub `HTTPTransport` (pattern:
`TransportInjectionTests`):

1. Decode live fixture → 36.0 used, weekly label, correct `resetsAt`.
2. `creditUsagePercent` absent with `currentPeriod` present → 0 used.
3. `auth.json` selection: auth.x.ai preferred over accounts.x.ai; expired →
   `loginRequired`; malformed → `unreadable`.
4. Provider maps 401 → `loginRequired`; 500 → `httpError`.
5. Monetary `{val}` minor-unit conversion.
