# Code Review: Claude Meter (Phase 1 — `ClaudeMeterCore`)

**Date:** 2026-06-22  
**Scope:** Swift package parsing `claude status` / `claude stats` CLI text into `ClaudeUsageSnapshot`.  
**Status:** Findings addressed in follow-up commit.

---

## High

### 1. `resolveYear` can return a timestamp in the past

`ResetTimeParser.resolveYear` only rolled the year forward when the candidate was **more than 24 hours** in the past. A date like `Jun 21 at 3pm` with `now = Jun 22 14:00` yielded a reset ~23 hours ago and was returned as-is.

SPECS §9.5 says to infer the **nearest future date**. Time-only parsing handled this (`date <= now` → tomorrow), but date+time parsing did not consistently.

**Fix:** After year injection, roll forward by one year while `candidate <= now`.

---

## Medium

### 2. Key-value parsing requires 2+ spaces after the colon

All metadata (`Version`, `Email`, `Model`, etc.) depended on `\s{2,}`. A CLI change to single-space alignment would silently drop every field.

**Fix:** Accept one or more spaces (`\s+`).

### 3. Missing timezone does not emit the spec-defined warning

SPECS §9.7 lists **"Reset timezone missing"** as a non-fatal warning. Implementation parsed with `fallbackTimeZone` but never warned when `(Asia/...)` was absent. Test name claimed a warning but did not assert it.

**Fix:** Emit warning when reset text has no parenthesized IANA timezone.

### 4. `parseModelTable` is untested

Model table parsing had zero tests. Risks: broad `name.contains("-")` heuristic, cost from last column, whitespace-splitting fragility.

**Fix:** Add fixtures and tests; tighten model name heuristic to require `claude` prefix.

### 5. Auth detection uses naive substring matching on raw text

Substring checks on the full blob could false-positive if session name, cwd, or org contained auth-like phrases.

**Fix:** Match auth patterns only on error-like lines (line-start / `Error:` prefix), not inside KV field values.

### 6. Usage block scan window is fixed at 6 lines

SPECS §9.4 says scan the **whole block**. Extra blank lines or wrapped content within 7 lines of the header could miss `% used` / `Resets` lines.

**Fix:** Scan until the next section header or key-value line.

### 7. `parseSeconds` strips all digits indiscriminately

`"1h 30m"` → `130`. Fragile for richer duration formats.

**Fix:** Parse explicit `digits`, `digits + s/sec/seconds` formats only.

---

## Low

### 8. `Setting sources` not parsed

Present in fixtures and SPECS §9.3 as optional field.

**Fix:** Add `settingSources` to `ClaudeUsageSnapshot`.

### 9. Negative percentages map to `.normal` severity

**Fix:** Map negative values to `.unknown`.

### 10. ANSI stripping is incomplete

CSI SGR covered; OSC and single-byte CSI not.

**Fix:** Extend stripper for OSC and `\u{9B}` CSI.

### 11. `lastSuccessfulPollAt` semantics in the parser

Parser set this to `now` on every parse; poller layer should own poll timestamps.

**Fix:** Leave `nil` in parser output.

### 12. No `Codable` round-trip tests

Models are `Codable` for `current.json` persistence but encode/decode was unverified.

**Fix:** Add round-trip test.

### 13. PII in committed fixtures

`full_status.txt` contained a real email and session name.

**Fix:** Replace with synthetic data.

### 14. Spec fixture gaps

Wrapped session name, model table variants, unknown model name format were missing.

**Fix:** Add fixtures and tests.

---

## Security

No significant issues for Phase 1: parser is pure string processing with no subprocess, network, or code execution.

---

## What was working well

1. Clean separation — parser has no AppKit/SwiftUI; `Sendable` throughout
2. Fatal vs warning split — core limits required; metadata degradation is non-fatal
3. Fixture-driven tests — good coverage for status blocks, ANSI, decimals, over-100%, auth, MCP
4. `ResetTimeParser` — solid format matrix; time-only roll-to-tomorrow logic is correct
5. `TokenParser` / `ANSIStripper` — small, focused, well-tested units
