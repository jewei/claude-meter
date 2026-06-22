# Code Review: Claude Meter Phase 2 (`8dd3b1c`)

**Date:** 2026-06-22  
**Scope:** `ClaudeCommandRunner`, `CLIPathDetector`, `SnapshotStore` (commit `8dd3b1c4407a947c44c1b3104d42e5e650feda2d`)  
**Status:** Findings addressed in follow-up commit.

---

## High

### 1. Pipe buffers not drained on timeout

When the timeout handler wins the `didResume` race, `terminationHandler` returns early **without** calling `readPipe`. A terminated child that has filled the stdout/stderr pipe buffer can remain blocked indefinitely (classic pipe deadlock).

**Fix:** Always drain pipes in `terminationHandler`; only gate `continuation.resume`.

---

## Medium

### 2. `last-error.json` declared but not implemented

`SnapshotStore` defines `lastErrorURL` but provides no read/write API. SPECS §11.1 requires `~/Library/Application Support/ClaudeMeter/last-error.json`.

**Fix:** Add `LastErrorRecord` and `writeLastError` / `readLastError` / `clearLastError`.

### 3. Phase 2 pipeline not wired (SPECS §907–914)

Phase 2 requires wiring parser output → snapshot model and integration tests. The commit adds isolated components but no orchestration layer connecting runner → parser → store, and no test exercising the full path.

**Fix:** Add `SnapshotPipeline` with integration test.

### 4. Subcommand limited to a single process argument

`process.arguments = [subcommand]` cannot express multi-argument invocations (e.g. `/bin/sh -c '…'`, future `status --json`).

**Fix:** Replace `statusSubcommand` / `statsSubcommand` strings with `[String]` argument arrays.

### 5. No stderr capture test

SPECS §8.2 requires stdout and stderr captured separately. Implementation supports it but tests never verify stderr.

**Fix:** Add stderr integration test via `/bin/sh -c`.

### 6. `HOME` may be empty string

`buildEnvironment()` sets `HOME` to `""` when unset, which can break CLIs that rely on home directory resolution.

**Fix:** Fall back to `FileManager.default.homeDirectoryForCurrentUser.path`.

---

## Low

### 7. Documentation drift in `SnapshotStore`

Class comment references manual `.tmp` + rename; implementation uses `Data.write(.atomic)`. Both are valid on APFS but comments should match code.

**Fix:** Align documentation with `Data.write(.atomic)`.

### 8. `MockCommandRunner` cannot simulate stats failures

Only `statusError` is supported; stats path always succeeds when output is configured.

**Fix:** Add optional `statsError`.

### 9. Missing `LANG` in subprocess environment

Minimal env is correct per spec, but omitting `LANG` can cause encoding issues for UTF-8 CLI output on some systems.

**Fix:** Set `LANG=C.UTF-8`.

### 10. `CLIPathDetector.detect()` untested

Tests cover `verify()` and search order but not the `detect()` walk itself.

**Fix:** Add test using a known system binary path.

### 11. Truncated-JSON test writes non-atomically

Test corrupts `current.json` via direct overwrite — acceptable for test setup but differs from production write path (behavior under test is still correct).

**No code change required.**

---

## Security

No critical issues. Subprocess runs a user-configured binary with a minimal environment — appropriate for a local menu bar app. No shell interpolation when using argument arrays (post-fix).

---

## What was working well

1. `OSAllocatedUnfairLock` for exactly-once continuation resume across timer and termination paths
2. Serial `DispatchQueue` isolating timer and termination logic from cooperative thread pool
3. `SnapshotStore` ISO8601 codec with pretty-printed sorted JSON
4. Real-process tests for echo, false, sleep/timeout
5. `MockCommandRunner` for deterministic unit tests
6. `Sendable` conformance throughout
