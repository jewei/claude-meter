# Multi-Account OAuth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Live per-account OAuth usage (session / weekly / Opus / extra-usage / plan / email) for every discovered Claude config dir — no open CLI session required — plus duplicate-login detection and auth-override env scrubbing.

**Architecture:** Claude Code stores one Keychain credential per config dir under service `Claude Code-credentials-<first 8 hex of SHA-256(config dir absolute path)>` (legacy unsuffixed entry for `~/.claude`) — verified empirically on this machine. Local identity (email, orgUuid, org name, rate-limit tier) lives in `<configDir>/.claude.json` (home-root `~/.claude.json` for the default dir) — no subprocess needed. A new `MultiAccountOAuth` Core module fetches `GET /api/oauth/usage` per account with that account's own bearer, captures the `anthropic-organization-id` response header, and merges readings into `ClaudeUsageSnapshot.accounts` (fill-only-missing; statusline stays authoritative for fresh session/weekly and active-account selection). `AccountInfo` already has email/org/plan fields and the popover already renders them, so schema and most UI are free.

**Tech Stack:** Swift 6 strict concurrency, CryptoKit (SHA-256), Security.framework (attributes-only enumeration + persistent-ref reads, no-UI policy), existing `HTTPTransport` injection for tests.

## Global Constraints

- Core package (`ClaudeMeterCore`) must not import AppKit/SwiftUI. Platform floor `.macOS(.v14)`, `swift-tools-version: 6.0`, strict concurrency.
- Build check: `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO`. Core tests: `swift test --package-path ClaudeMeterCore`.
- All new files are Core-package files (plus edits to existing app files) — **no `project.pbxproj` changes needed** (SPM auto-discovers Core sources; `AppState.swift`/`PopoverView.swift` are already project members).
- Never write refreshed auto tokens back to Claude Code's Keychain (in-memory cache only).
- Commit messages: Conventional Commits, subject ≤50 chars, **no Co-Authored-By / attribution lines**.
- Keychain reads: attributes-only enumeration (`kSecReturnAttributes`, never `kSecReturnData` in list queries); data reads via persistent ref under the no-UI policy (`applyNoUI`).
- OAuth usage GETs respect the process-wide 429 backoff (`OAuthSharedState.isRateLimited`) and record `Retry-After` on 429.
- Non-goals (explicitly out of scope): account routing/rotation, TOFU org-pin change detection, per-account notifications rework, `claude auth status` subprocess (local `.claude.json` covers identity for display).

## Verified Facts (from spike, 2026-07-13)

- Keychain services on this machine: `Claude Code-credentials` (legacy, default dir) + `Claude Code-credentials-4631b25c` (= SHA-256 of `/Users/jewei/.claude-oneone-it` first 8 hex) + `Claude Code-credentials-48c8f98c` (= `/Users/jewei/.claude-oneone-tech`). Hash input is the **absolute path, no trailing slash**.
- `claude auth status --json` works (2.1.207) but is not needed.
- `<configDir>/.claude.json` → `oauthAccount` object with `emailAddress`, `organizationUuid`, `organizationName`, `displayName`, `organizationRateLimitTier` (e.g. `default_claude_max_5x`; may be absent). Default dir: file is at `~/.claude.json` (home root), **not** `~/.claude/.claude.json`.
- Keychain credentials JSON (`claudeAiOauth`) may carry `rateLimitTier` alongside `subscriptionType`.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `ClaudeMeterCore/Sources/ClaudeMeterCore/AuthEnv.swift` | create | Auth-override env-var scrub for provider subprocesses |
| `ClaudeMeterCore/Sources/ClaudeMeterCore/AccountIdentity.swift` | create | Parse `<dir>/.claude.json` local identity |
| `ClaudeMeterCore/Sources/ClaudeMeterCore/MultiAccountOAuth.swift` | create | Hash/service mapping, per-account usage fetch, snapshot merge, duplicate detection |
| `ClaudeMeterCore/Sources/ClaudeMeterCore/OAuthKeychain.swift` | modify | Per-config-dir credential read; `rateLimitTier` parse |
| `ClaudeMeterCore/Sources/ClaudeMeterCore/ClaudePlan.swift` | modify | Max 5x / Max 20x tier names |
| `ClaudeMeterCore/Sources/ClaudeMeterCore/CodexAppServerSource.swift` | modify | Scrub env before spawning `codex app-server` |
| `ClaudeMeter/AppState.swift` | modify | Interval-gated multi-account fetch + merge into snapshot |
| `ClaudeMeter/PopoverView.swift` | modify | Duplicate-login badge |
| `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/AuthEnvTests.swift` | create | |
| `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/AccountIdentityTests.swift` | create | |
| `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/MultiAccountOAuthTests.swift` | create | |
| `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/StatusAndPlanTests.swift` | modify | tier-name cases |
| `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/OAuthKeychainTests.swift` | modify | service-matching cases |

Branch first: `git checkout -b feature/multi-account-oauth`

---

### Task 1: AuthEnv scrub + Codex spawn hardening

**Files:**
- Create: `ClaudeMeterCore/Sources/ClaudeMeterCore/AuthEnv.swift`
- Modify: `ClaudeMeterCore/Sources/ClaudeMeterCore/CodexAppServerSource.swift` (the `Process` launch site, `process.environment = env` around line 132, and the `env:` defaults at lines 5/73)
- Test: `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/AuthEnvTests.swift`

**Interfaces:**
- Produces: `AuthEnv.scrubbed(_ base: [String: String]) -> [String: String]`, `AuthEnv.overrideVariables: [String]`

- [ ] **Step 1: Write the failing test**

```swift
import Testing

@testable import ClaudeMeterCore

struct AuthEnvTests {
    @Test func scrubRemovesAuthOverrides() {
        let base = [
            "PATH": "/usr/bin",
            "OPENAI_API_KEY": "sk-x",
            "CODEX_API_KEY": "k",
            "CODEX_AGENT_IDENTITY": "i",
            "ANTHROPIC_API_KEY": "sk-ant",
            "ANTHROPIC_AUTH_TOKEN": "t",
            "ANTHROPIC_BASE_URL": "https://evil.example",
            "CLAUDE_CODE_OAUTH_TOKEN": "o",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "OPENAI_BASE_URL": "https://evil.example",
            "HOME": "/Users/x",
        ]
        let scrubbed = AuthEnv.scrubbed(base)
        #expect(scrubbed["PATH"] == "/usr/bin")
        #expect(scrubbed["HOME"] == "/Users/x")
        for key in AuthEnv.overrideVariables {
            #expect(scrubbed[key] == nil, "\(key) must be scrubbed")
        }
    }

    @Test func scrubKeepsUnrelatedVariables() {
        let scrubbed = AuthEnv.scrubbed(["FOO": "bar"])
        #expect(scrubbed == ["FOO": "bar"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ClaudeMeterCore --filter AuthEnvTests`
Expected: FAIL — `cannot find 'AuthEnv' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Environment variables that would silently redirect a provider CLI or API call
/// to a different account/provider than the one selected (API keys, alternate
/// providers, base-URL overrides). Scrubbed from every provider subprocess the
/// app spawns, so an inherited terminal env can't hijack a read.
public enum AuthEnv {
    public static let overrideVariables: [String] = [
        // Anthropic direct
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_OAUTH_TOKEN",
        // Claude Code alternate providers
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
        "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
        // OpenAI / Codex
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "CODEX_AGENT_IDENTITY",
    ]

    /// `base` minus every auth-override variable.
    public static func scrubbed(_ base: [String: String]) -> [String: String] {
        var env = base
        for key in overrideVariables { env[key] = nil }
        return env
    }
}
```

Note: unlike headroom we deliberately do NOT scrub `AWS_PROFILE`/`AWS_REGION`/`GOOGLE_APPLICATION_CREDENTIALS` — we never launch the `claude` CLI, and those are only meaningful to it; scrubbing generic cloud vars from `codex app-server` buys nothing.

- [ ] **Step 4: Wire into CodexAppServerSource**

In `CodexAppServerSource.swift`, at the `Process` configuration site (`process.environment = env`, ~line 132), change to:

```swift
process.environment = AuthEnv.scrubbed(env)
```

Leave `CodexCLILocator.resolve(env:)` unscrubbed — it only reads `PATH`/`CODEX_CLI_PATH`, which are not auth overrides.

- [ ] **Step 5: Run tests + build**

Run: `swift test --package-path ClaudeMeterCore --filter AuthEnvTests` → PASS
Run: `swift test --package-path ClaudeMeterCore --filter CodexUsageTests` → PASS (no regressions)

- [ ] **Step 6: Commit**

```bash
git add ClaudeMeterCore/Sources/ClaudeMeterCore/AuthEnv.swift \
        ClaudeMeterCore/Sources/ClaudeMeterCore/CodexAppServerSource.swift \
        ClaudeMeterCore/Tests/ClaudeMeterCoreTests/AuthEnvTests.swift
git commit -m "feat: scrub auth-override env vars from codex spawn"
```

---

### Task 2: Plan tier names (Max 5x / Max 20x) + `rateLimitTier` in credentials

**Files:**
- Modify: `ClaudeMeterCore/Sources/ClaudeMeterCore/ClaudePlan.swift`
- Modify: `ClaudeMeterCore/Sources/ClaudeMeterCore/OAuthKeychain.swift` (`OAuthCredentials` + `parse`)
- Test: `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/StatusAndPlanTests.swift`, `OAuthKeychainTests.swift`

**Interfaces:**
- Produces: `OAuthCredentials.rateLimitTier: String?`; `ClaudePlan.displayName(subscriptionType:rateLimitTier:)` returning `"Max 5x"` / `"Max 20x"` for matching tiers.

- [ ] **Step 1: Write the failing tests**

Append to `StatusAndPlanTests.swift`:

```swift
@Test func planTierNames() {
    #expect(ClaudePlan.displayName(subscriptionType: nil, rateLimitTier: "default_claude_max_5x") == "Max 5x")
    #expect(ClaudePlan.displayName(subscriptionType: nil, rateLimitTier: "default_claude_max_20x") == "Max 20x")
    // subscriptionType stays preferred, but a bare "max" upgrades via tier detail
    #expect(ClaudePlan.displayName(subscriptionType: "max", rateLimitTier: "default_claude_max_5x") == "Max 5x")
    #expect(ClaudePlan.displayName(subscriptionType: "max", rateLimitTier: nil) == "Max")
    #expect(ClaudePlan.displayName(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
}
```

Append to `OAuthKeychainTests.swift`:

```swift
@Test func parseReadsRateLimitTier() {
    let json = """
        {"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1999999999999,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}
        """
    let creds = OAuthKeychain.parseForTesting(json)
    #expect(creds?.rateLimitTier == "default_claude_max_20x")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeMeterCore --filter "StatusAndPlanTests|OAuthKeychainTests"`
Expected: FAIL — no `rateLimitTier` member; tier name assertions fail (`"Max"` ≠ `"Max 5x"`)

- [ ] **Step 3: Implement**

`ClaudePlan.swift` — replace `displayName(subscriptionType:rateLimitTier:)` and `from(_:)`:

```swift
    /// Resolves a display name from any available hint. A tier string with 5x/20x
    /// detail refines a bare "Max" from `subscriptionType`.
    public static func displayName(subscriptionType: String?, rateLimitTier: String? = nil)
        -> String?
    {
        if let detailed = maxTierName(rateLimitTier) { return detailed }
        return from(subscriptionType) ?? from(rateLimitTier)
    }

    /// "Max 5x" / "Max 20x" when the tier string carries the multiplier.
    private static func maxTierName(_ raw: String?) -> String? {
        guard let tier = raw?.lowercased() else { return nil }
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        return nil
    }
```

(`from(_:)` unchanged.)

`OAuthKeychain.swift`:
- Add `public var rateLimitTier: String?` to `OAuthCredentials` + init parameter `rateLimitTier: String? = nil` (assign in init).
- In `parse(_:)`, add `rateLimitTier: oauth["rateLimitTier"] as? String` to the returned `OAuthCredentials`.
- In `OAuthPipeline.poll` (~line 82) change plan resolution to `ClaudePlan.displayName(subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier)`; same for the refreshed-plan path (~line 111) and `fetchEnrichment` (~line 252, currently passes `rateLimitTier: nil`).
- In `performTokenRefresh` and the `fetchEnrichment` credential rebuild, carry `rateLimitTier: credentials.rateLimitTier` through so a refresh doesn't drop it.

- [ ] **Step 4: Run tests**

Run: `swift test --package-path ClaudeMeterCore --filter "StatusAndPlanTests|OAuthKeychainTests|OAuthPipelineTests"` → PASS

- [ ] **Step 5: Commit**

```bash
git add ClaudeMeterCore/Sources/ClaudeMeterCore/ClaudePlan.swift \
        ClaudeMeterCore/Sources/ClaudeMeterCore/OAuthKeychain.swift \
        ClaudeMeterCore/Sources/ClaudeMeterCore/OAuthPipeline.swift \
        ClaudeMeterCore/Tests/ClaudeMeterCoreTests/StatusAndPlanTests.swift \
        ClaudeMeterCore/Tests/ClaudeMeterCoreTests/OAuthKeychainTests.swift
git commit -m "feat: Max 5x/20x plan names from rateLimitTier"
```

---

### Task 3: Per-config-dir Keychain credential read

**Files:**
- Modify: `ClaudeMeterCore/Sources/ClaudeMeterCore/OAuthKeychain.swift`
- Create: `ClaudeMeterCore/Sources/ClaudeMeterCore/MultiAccountOAuth.swift` (hash helper only in this task)
- Test: `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/MultiAccountOAuthTests.swift`, `OAuthKeychainTests.swift`

**Interfaces:**
- Produces:
  - `MultiAccountOAuth.hashedServiceSuffix(forPath: String) -> String` — first 8 lowercase hex of SHA-256(path bytes).
  - `OAuthKeychain.credentialServices(forConfigDirPath: String, isDefault: Bool) -> [String]` — candidate service names, preferred first.
  - `OAuthKeychain.loadResult(configDirPath: String, isDefault: Bool) -> KeychainReadResult<OAuthCredentials>` — per-account credential read.

- [ ] **Step 1: Write the failing tests**

Create `MultiAccountOAuthTests.swift`:

```swift
import Foundation
import Testing

@testable import ClaudeMeterCore

struct MultiAccountOAuthTests {
    @Test func hashedServiceSuffixMatchesSHA256Prefix() {
        // sha256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        #expect(MultiAccountOAuth.hashedServiceSuffix(forPath: "abc") == "ba7816bf")
        // Empirically verified live mapping (see plan header):
        #expect(
            MultiAccountOAuth.hashedServiceSuffix(forPath: "/Users/jewei/.claude-oneone-tech")
                == "48c8f98c")
    }
}
```

Append to `OAuthKeychainTests.swift`:

```swift
@Test func credentialServiceCandidates() {
    let custom = OAuthKeychain.credentialServices(
        forConfigDirPath: "/Users/jewei/.claude-oneone-tech", isDefault: false)
    #expect(custom == ["Claude Code-credentials-48c8f98c"])

    let def = OAuthKeychain.credentialServices(
        forConfigDirPath: "/Users/jewei/.claude", isDefault: true)
    // Default dir: legacy unsuffixed first, hashed as fallback.
    #expect(def.first == "Claude Code-credentials")
    #expect(def.count == 2)
    #expect(def[1].hasPrefix("Claude Code-credentials-"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeMeterCore --filter "MultiAccountOAuthTests|OAuthKeychainTests"`
Expected: FAIL — `cannot find 'MultiAccountOAuth'`, no member `credentialServices`

- [ ] **Step 3: Implement**

Create `MultiAccountOAuth.swift`:

```swift
import CryptoKit
import Foundation

/// Per-account OAuth usage: maps each discovered Claude config dir to its own
/// Keychain credential and usage reading. Claude Code (≈2.1.52+) namespaces the
/// Keychain entry per config dir as `Claude Code-credentials-<hash>` where
/// `<hash>` is the first 8 hex chars of SHA-256 of the config dir's absolute
/// path (verified empirically); the default `~/.claude` keeps the legacy
/// unsuffixed service.
public enum MultiAccountOAuth {

    /// First 8 lowercase hex chars of SHA-256 over the path's UTF-8 bytes.
    public static func hashedServiceSuffix(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
    }
}
```

(`String(...).prefix(8)` returns Substring — wrap: `String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))`. `.lowercased()` is redundant with `%02x` but harmless; drop it.)

Final body:

```swift
    public static func hashedServiceSuffix(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
```

In `OAuthKeychain.swift` add:

```swift
    /// Candidate Keychain service names for a config dir's credentials, preferred
    /// first. Custom dirs use only their hashed service; the default dir prefers
    /// the legacy unsuffixed entry with the hashed one as a fallback (newer
    /// Claude Code may namespace even the default install).
    public static func credentialServices(forConfigDirPath path: String, isDefault: Bool)
        -> [String]
    {
        let hashed = service + "-" + MultiAccountOAuth.hashedServiceSuffix(forPath: path)
        return isDefault ? [service, hashed] : [hashed]
    }

    /// Reads the credentials bound to one config dir (multi-account read path).
    /// Same attributes-only enumeration + persistent-ref read as the single-slot
    /// path, but filtered to the dir's candidate services instead of "newest wins".
    public static func loadResult(configDirPath: String, isDefault: Bool)
        -> KeychainReadResult<OAuthCredentials>
    {
        let account = claudeCodeAccount
        guard !account.isEmpty else { return .missing }
        #if canImport(Security)
            let services = credentialServices(forConfigDirPath: path(configDirPath), isDefault: isDefault)
            return parseResult(readCredential(services: services, account: account))
        #else
            return .missing
        #endif
    }

    /// Standardizes a config dir path the same way the hash input expects:
    /// absolute, symlinks resolved, no trailing slash.
    private static func path(_ raw: String) -> String {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }
```

And the Security-side helper (inside the existing `#if canImport(Security)` block), reusing the enumeration pattern from `readNewestClaudeCodeCredential`:

```swift
        /// Reads the first present service from `services` (preference order) via
        /// attributes-only enumeration + persistent-ref data read. `.missing` only
        /// when none of the candidates exist.
        private static func readCredential(services: [String], account: String)
            -> KeychainReadResult<String>
        {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: account,
                kSecReturnAttributes: true,
                kSecReturnPersistentRef: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess: break
            case errSecItemNotFound: return .missing
            default: return .temporarilyUnavailable
            }
            guard let items = result as? [[String: Any]] else { return .missing }
            for service in services {
                if let ref = items.first(where: {
                    ($0[kSecAttrService as String] as? String) == service
                })?[kSecValuePersistentRef as String] as? Data {
                    return readCredentialData(persistentRef: ref)
                }
            }
            return .missing
        }
```

Note on the hash input: the spike matched both the raw path and the resolved path (no symlinks involved on the test machine). Claude Code hashes the value of `$CLAUDE_CONFIG_DIR` as given; we standardize via `resolvingSymlinksInPath().standardizedFileURL.path`, which equals the raw absolute path in the normal case. If a user reaches a config dir through a symlink, the hashed lookup may miss → `.missing` → that account simply shows statusline-only data (graceful degradation, no wrong data).

- [ ] **Step 4: Run tests**

Run: `swift test --package-path ClaudeMeterCore --filter "MultiAccountOAuthTests|OAuthKeychainTests"` → PASS

- [ ] **Step 5: Commit**

```bash
git add ClaudeMeterCore/Sources/ClaudeMeterCore/MultiAccountOAuth.swift \
        ClaudeMeterCore/Sources/ClaudeMeterCore/OAuthKeychain.swift \
        ClaudeMeterCore/Tests/ClaudeMeterCoreTests/MultiAccountOAuthTests.swift \
        ClaudeMeterCore/Tests/ClaudeMeterCoreTests/OAuthKeychainTests.swift
git commit -m "feat: per-config-dir keychain credential read"
```

---

### Task 4: Local account identity from `.claude.json`

**Files:**
- Create: `ClaudeMeterCore/Sources/ClaudeMeterCore/AccountIdentity.swift`
- Test: `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/AccountIdentityTests.swift`

**Interfaces:**
- Produces:

```swift
public struct ClaudeAccountIdentity: Sendable, Equatable {
    public let email: String?
    public let organizationUuid: String?
    public let organizationName: String?
    public let displayName: String?
    public let rateLimitTier: String?
}
public enum AccountIdentityReader {
    public static func identityFilePath(configDir: URL, home: URL) -> URL
    public static func loadLocal(configDir: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeAccountIdentity?
    static func parse(_ data: Data) -> ClaudeAccountIdentity?   // internal, for tests
}
```

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import ClaudeMeterCore

struct AccountIdentityTests {
    @Test func parsesOauthAccount() {
        let json = """
            {"oauthAccount":{"emailAddress":"a@b.com","organizationUuid":"org-1",
             "organizationName":"A's Org","displayName":"A",
             "organizationRateLimitTier":"default_claude_max_5x"},"other":123}
            """
        let identity = AccountIdentityReader.parse(Data(json.utf8))
        #expect(identity?.email == "a@b.com")
        #expect(identity?.organizationUuid == "org-1")
        #expect(identity?.organizationName == "A's Org")
        #expect(identity?.displayName == "A")
        #expect(identity?.rateLimitTier == "default_claude_max_5x")
    }

    @Test func missingOauthAccountIsNil() {
        #expect(AccountIdentityReader.parse(Data("{}".utf8)) == nil)
        #expect(AccountIdentityReader.parse(Data("not json".utf8)) == nil)
    }

    @Test func identityFileLocation() {
        let home = URL(fileURLWithPath: "/Users/x")
        // Default dir -> home-root ~/.claude.json (NOT inside ~/.claude/).
        let def = AccountIdentityReader.identityFilePath(
            configDir: home.appendingPathComponent(".claude"), home: home)
        #expect(def.path == "/Users/x/.claude.json")
        // Custom dir -> <dir>/.claude.json.
        let custom = AccountIdentityReader.identityFilePath(
            configDir: home.appendingPathComponent(".claude-work"), home: home)
        #expect(custom.path == "/Users/x/.claude-work/.claude.json")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ClaudeMeterCore --filter AccountIdentityTests`
Expected: FAIL — `cannot find 'AccountIdentityReader'`

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Identity bound inside a Claude config dir, read from local metadata only —
/// no network, no subprocess. Claude Code writes `oauthAccount` (email, org,
/// tier) into `<configDir>/.claude.json`; for the DEFAULT dir the file lives at
/// the home root (`~/.claude.json`), not inside `~/.claude/`.
public struct ClaudeAccountIdentity: Sendable, Equatable {
    public let email: String?
    public let organizationUuid: String?
    public let organizationName: String?
    public let displayName: String?
    public let rateLimitTier: String?

    public init(
        email: String?, organizationUuid: String?, organizationName: String?,
        displayName: String?, rateLimitTier: String?
    ) {
        self.email = email
        self.organizationUuid = organizationUuid
        self.organizationName = organizationName
        self.displayName = displayName
        self.rateLimitTier = rateLimitTier
    }
}

public enum AccountIdentityReader {

    /// Where the identity metadata lives for a config dir (see type doc).
    public static func identityFilePath(configDir: URL, home: URL) -> URL {
        let isDefault =
            configDir.standardizedFileURL.path
            == home.appendingPathComponent(".claude").standardizedFileURL.path
        return isDefault
            ? home.appendingPathComponent(".claude.json")
            : configDir.appendingPathComponent(".claude.json")
    }

    public static func loadLocal(
        configDir: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClaudeAccountIdentity? {
        let url = identityFilePath(configDir: configDir, home: home)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// `nil` when the file has no `oauthAccount` (not logged in) or isn't JSON.
    static func parse(_ data: Data) -> ClaudeAccountIdentity? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = obj["oauthAccount"] as? [String: Any]
        else { return nil }
        return ClaudeAccountIdentity(
            email: oauth["emailAddress"] as? String,
            organizationUuid: oauth["organizationUuid"] as? String,
            organizationName: oauth["organizationName"] as? String,
            displayName: oauth["displayName"] as? String,
            rateLimitTier: (oauth["organizationRateLimitTier"] as? String)
                ?? (oauth["userRateLimitTier"] as? String)
        )
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --package-path ClaudeMeterCore --filter AccountIdentityTests` → PASS

- [ ] **Step 5: Commit**

```bash
git add ClaudeMeterCore/Sources/ClaudeMeterCore/AccountIdentity.swift \
        ClaudeMeterCore/Tests/ClaudeMeterCoreTests/AccountIdentityTests.swift
git commit -m "feat: local account identity from .claude.json"
```

---

### Task 5: Per-account usage fetch

**Files:**
- Modify: `ClaudeMeterCore/Sources/ClaudeMeterCore/MultiAccountOAuth.swift`
- Modify: `ClaudeMeterCore/Sources/ClaudeMeterCore/OAuthPipeline.swift` (make three internals reachable: see below)
- Test: `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/MultiAccountOAuthTests.swift`

**Interfaces:**
- Consumes: `OAuthKeychain.loadResult(configDirPath:isDefault:)` (Task 3), `AccountIdentityReader.loadLocal(configDir:home:)` (Task 4), `UsageResponse`/`QuotaEntry` decode + `usageRequest(token:)` + `parseEpochOrISODate` from `OAuthPipeline.swift`, `AccountConfig` from `ConfigDirDiscovery.swift`, `UsageThresholds`.
- Produces:

```swift
public struct OAuthAccountReading: Sendable, Equatable {
    public let accountKey: String       // AccountConfig.id
    public let label: String            // AccountConfig.label
    public let email: String?
    public let plan: String?
    public let organizationId: String?  // response header, else .claude.json orgUuid
    public let limits: LimitInfo
    public let severity: UsageSeverity
}
public enum MultiAccountOAuth {
    public static func fetchAll(
        accounts: [AccountConfig],
        home: URL,
        thresholds: UsageThresholds,
        transport: any HTTPTransport,
        credentialsLoader: @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials>,
        now: Date
    ) async -> [OAuthAccountReading]
}
```

`credentialsLoader` is injected (defaults wired at the AppState call site to `OAuthKeychain.loadResult(configDirPath:isDefault:)`) so tests run without a Keychain.

- [ ] **Step 1: Prepare internals**

In `OAuthPipeline.swift`, no visibility changes are needed for `UsageResponse`/`QuotaEntry` (already `internal`, same module). Extract the request builder so `MultiAccountOAuth` can reuse it: change `private static func usageRequest(token:)` to `static func usageRequest(token: String) -> URLRequest` (drop `private`). Also drop `private` from `fileprivate`/`private` on nothing else — `OAuthSharedState` stays private; multi-account fetch checks/records backoff via two new internal statics on `OAuthPipeline`:

```swift
    /// Backoff bridge for the multi-account fetcher (OAuthSharedState is private).
    static func isRateLimited(now: Date) -> Bool {
        OAuthSharedState.isRateLimited(now: now)
    }
    static func recordRateLimit(retryAfter: Date?, now: Date) {
        OAuthSharedState.recordRateLimit(retryAfter: retryAfter, now: now)
    }
```

- [ ] **Step 2: Write the failing test**

Append to `MultiAccountOAuthTests.swift` (transport stub mirrors `TransportInjectionTests` style):

```swift
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Data, HTTPURLResponse)] = []
    var requests: [URLRequest] = []
    private let lock = NSLock()

    func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (
        Data, HTTPURLResponse
    ) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return responses.removeFirst()
    }
}

extension MultiAccountOAuthTests {
    private static func usageBody(session: Double, week: Double) -> Data {
        Data(
            """
            {"five_hour":{"utilization":\(session),"resets_at":"2099-01-01T00:00:00Z"},
             "seven_day":{"utilization":\(week),"resets_at":"2099-01-02T00:00:00Z"},
             "seven_day_opus":{"utilization":10,"resets_at":"2099-01-02T00:00:00Z"}}
            """.utf8)
    }

    private static func httpResponse(status: Int, orgId: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: status, httpVersion: nil,
            headerFields: orgId.map { ["anthropic-organization-id": $0] })!
    }

    @Test func fetchAllReadsEachAccountWithItsOwnToken() async {
        let transport = StubTransport()
        transport.responses = [
            (Self.usageBody(session: 30, week: 40), Self.httpResponse(status: 200, orgId: "org-A")),
            (Self.usageBody(session: 70, week: 90), Self.httpResponse(status: 200, orgId: "org-B")),
        ]
        let accounts = [
            AccountConfig(id: "claude", label: "default", configDir: URL(fileURLWithPath: "/tmp/none/.claude")),
            AccountConfig(id: "claude-work", label: "work", configDir: URL(fileURLWithPath: "/tmp/none/.claude-work")),
        ]
        let creds: @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials> = { path, _ in
            let token = path.hasSuffix(".claude-work") ? "tok-work" : "tok-default"
            return .found(
                OAuthCredentials(
                    accessToken: token, refreshToken: "r",
                    expiresAt: Date(timeIntervalSinceNow: 3600), subscriptionType: "max"))
        }
        let readings = await MultiAccountOAuth.fetchAll(
            accounts: accounts, home: URL(fileURLWithPath: "/tmp/none"),
            thresholds: .default, transport: transport,
            credentialsLoader: creds, now: Date())

        #expect(readings.count == 2)
        #expect(transport.requests.count == 2)
        #expect(
            transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer tok-default")
        #expect(
            transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok-work")
        #expect(readings[0].organizationId == "org-A")
        #expect(readings[1].organizationId == "org-B")
        #expect(readings[1].limits.currentSession?.percentUsed == 70)
        #expect(readings[1].limits.currentWeekOpus?.percentUsed == 10)
        #expect(readings[1].severity == .warning)  // 90% week >= warning 80
    }

    @Test func fetchAllSkipsAccountsWithoutCredentials() async {
        let transport = StubTransport()
        transport.responses = [
            (Self.usageBody(session: 5, week: 5), Self.httpResponse(status: 200, orgId: nil))
        ]
        let accounts = [
            AccountConfig(id: "claude", label: "default", configDir: URL(fileURLWithPath: "/tmp/none/.claude")),
            AccountConfig(id: "claude-x", label: "x", configDir: URL(fileURLWithPath: "/tmp/none/.claude-x")),
        ]
        let creds: @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials> = { path, _ in
            path.hasSuffix(".claude")
                ? .found(
                    OAuthCredentials(
                        accessToken: "t", refreshToken: "r",
                        expiresAt: Date(timeIntervalSinceNow: 3600)))
                : .missing
        }
        let readings = await MultiAccountOAuth.fetchAll(
            accounts: accounts, home: URL(fileURLWithPath: "/tmp/none"),
            thresholds: .default, transport: transport,
            credentialsLoader: creds, now: Date())
        #expect(readings.count == 1)
        #expect(readings[0].accountKey == "claude")
        #expect(transport.requests.count == 1)
    }

    @Test func fetchAllStopsOn429AndRecordsBackoff() async {
        let transport = StubTransport()
        transport.responses = [
            (Data("{}".utf8), Self.httpResponse(status: 429, orgId: nil))
        ]
        let accounts = [
            AccountConfig(id: "claude", label: "default", configDir: URL(fileURLWithPath: "/tmp/none/.claude")),
            AccountConfig(id: "claude-y", label: "y", configDir: URL(fileURLWithPath: "/tmp/none/.claude-y")),
        ]
        let creds: @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials> = { _, _ in
            .found(
                OAuthCredentials(
                    accessToken: "t", refreshToken: "r",
                    expiresAt: Date(timeIntervalSinceNow: 3600)))
        }
        let readings = await MultiAccountOAuth.fetchAll(
            accounts: accounts, home: URL(fileURLWithPath: "/tmp/none"),
            thresholds: .default, transport: transport,
            credentialsLoader: creds, now: Date())
        // First account 429s -> provider-wide stop; second never attempted.
        #expect(readings.isEmpty)
        #expect(transport.requests.count == 1)
    }
}
```

Note: the 429 test records into the process-wide backoff, which other tests read. Use a far-past `now` (e.g. `Date(timeIntervalSince1970: 0)`) in this test's `fetchAll` call and response `Retry-After` absent → backoff = now+60 s = epoch+60, long expired for every other test that uses `Date()`. Adjust the call: `now: Date(timeIntervalSince1970: 0)`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path ClaudeMeterCore --filter MultiAccountOAuthTests`
Expected: FAIL — `fetchAll` not found

- [ ] **Step 4: Implement `fetchAll`**

Append to `MultiAccountOAuth.swift`:

```swift
/// One account's live OAuth usage reading.
public struct OAuthAccountReading: Sendable, Equatable {
    public let accountKey: String
    public let label: String
    public let email: String?
    public let plan: String?
    public let organizationId: String?
    public let limits: LimitInfo
    public let severity: UsageSeverity
}

extension MultiAccountOAuth {

    /// Fetches every account's usage with that account's own bearer, sequentially
    /// (small N; keeps 429 handling simple). An account with no credentials, an
    /// expired token, or a failed request is skipped — statusline data still
    /// covers it. A 429 aborts the remaining accounts and records the
    /// provider-wide backoff. Never throws.
    public static func fetchAll(
        accounts: [AccountConfig],
        home: URL,
        thresholds: UsageThresholds,
        transport: any HTTPTransport,
        credentialsLoader: @Sendable (String, Bool) -> KeychainReadResult<OAuthCredentials>,
        now: Date
    ) async -> [OAuthAccountReading] {
        var readings: [OAuthAccountReading] = []
        for account in accounts {
            if OAuthPipeline.isRateLimited(now: now) { break }
            let dirPath = account.configDir.resolvingSymlinksInPath().standardizedFileURL.path
            let isDefault = account.id == "claude"
            guard let creds = credentialsLoader(dirPath, isDefault).value, !creds.isExpired
            else { continue }
            let identity = AccountIdentityReader.loadLocal(configDir: account.configDir, home: home)
            do {
                let (data, http) = try await transport.send(
                    OAuthPipeline.usageRequest(token: creds.accessToken), retry: .none)
                guard http.statusCode == 200 else {
                    if http.statusCode == 429 {
                        OAuthPipeline.recordRateLimit(
                            retryAfter: OAuthPipeline.retryAfterDate(from: http, now: now),
                            now: now)
                        break
                    }
                    continue
                }
                let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                readings.append(
                    reading(
                        account: account, usage: usage, identity: identity, creds: creds,
                        orgHeader: http.value(forHTTPHeaderField: "anthropic-organization-id"),
                        thresholds: thresholds))
            } catch {
                continue
            }
        }
        return readings
    }

    /// Pure assembly of one reading (exposed for tests via fetchAll).
    private static func reading(
        account: AccountConfig,
        usage: UsageResponse,
        identity: ClaudeAccountIdentity?,
        creds: OAuthCredentials,
        orgHeader: String?,
        thresholds: UsageThresholds
    ) -> OAuthAccountReading {
        func window(_ entry: QuotaEntry?) -> LimitWindow? {
            guard let entry, let utilization = entry.utilization else { return nil }
            return LimitWindow(
                percentUsed: utilization, resetsAt: parseEpochOrISODate(entry.resetsAt))
        }
        let limits = LimitInfo(
            currentSession: window(usage.fiveHour) ?? LimitWindow(),
            currentWeekAllModels: window(usage.sevenDay) ?? LimitWindow(),
            currentWeekOpus: window(usage.sevenDayOpus),
            extraUsage: usage.extraUsage?.model)
        let severity = [
            usage.fiveHour?.utilization, usage.sevenDay?.utilization,
            usage.sevenDayOpus?.utilization,
        ].reduce(UsageSeverity.unknown) { UsageSeverity.highest($0, thresholds.severity(for: $1)) }
        return OAuthAccountReading(
            accountKey: account.id,
            label: account.label,
            email: identity?.email,
            plan: ClaudePlan.displayName(
                subscriptionType: creds.subscriptionType,
                rateLimitTier: creds.rateLimitTier ?? identity?.rateLimitTier),
            organizationId: orgHeader ?? identity?.organizationUuid,
            limits: limits,
            severity: severity)
    }
}
```

Adjust to the real `LimitInfo` initializer signature (check `Models.swift`; if `currentSession`/`currentWeekAllModels` are optional, drop the `?? LimitWindow()`).

Deliberate simplification: no token refresh in the multi-account path (YAGNI for v1) — Claude Code refreshes its own Keychain entries as the user works; an expired secondary-account token just means that account stays statusline-only until its next local use. The active account keeps full refresh via the existing single-slot `OAuthPipeline`. Document in AGENTS.md (Task 8).

- [ ] **Step 5: Run tests**

Run: `swift test --package-path ClaudeMeterCore --filter MultiAccountOAuthTests` → PASS
Run: `swift test --package-path ClaudeMeterCore` → all green (watch `OAuthPipelineTests` for the visibility changes)

- [ ] **Step 6: Commit**

```bash
git add ClaudeMeterCore/Sources/ClaudeMeterCore/MultiAccountOAuth.swift \
        ClaudeMeterCore/Sources/ClaudeMeterCore/OAuthPipeline.swift \
        ClaudeMeterCore/Tests/ClaudeMeterCoreTests/MultiAccountOAuthTests.swift
git commit -m "feat: per-account oauth usage fetch"
```

---

### Task 6: Snapshot merge + duplicate detection (pure Core logic)

**Files:**
- Modify: `ClaudeMeterCore/Sources/ClaudeMeterCore/MultiAccountOAuth.swift`
- Test: `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/MultiAccountOAuthTests.swift`

**Interfaces:**
- Consumes: `OAuthAccountReading` (Task 5), `ClaudeUsageSnapshot`/`AccountUsage`/`AccountInfo` (Models.swift).
- Produces:
  - `MultiAccountOAuth.merge(readings: [OAuthAccountReading], into: ClaudeUsageSnapshot, now: Date) -> ClaudeUsageSnapshot`
  - `MultiAccountOAuth.duplicateOrgAccountKeys(_ accounts: [AccountUsage]) -> Set<String>`

**Merge rules (encode exactly):**
1. Readings index by `accountKey`.
2. For each existing `AccountUsage` in `snapshot.accounts` with a matching reading:
   - `account`: fill `email`/`plan`/`organization` only where currently nil (user/statusline data wins; `organization` gets the reading's `organizationId`).
   - `limits.currentWeekOpus`: set from reading when currently nil.
   - `limits.extraUsage`: set from reading when currently nil.
   - `limits.currentSession` / `currentWeekAllModels`: replace only when the existing window has `percentUsed == nil` (statusline fresh data wins; OAuth fills gaps).
3. Readings with no matching entry → append `AccountUsage(id:label:account:limits:lastSuccessfulPollAt:severity:isActive:)` with `isActive: false`, `lastSuccessfulPollAt: now`, `account: AccountInfo(loginMethod: "OAuth", organization: organizationId, email: email, plan: plan)`.
4. `snapshot.accounts == nil`: build a list only when ≥2 readings (preserves the single-account `current.json` byte-compat promise). Active = reading with `accountKey == "claude"` if present, else the first; that entry additionally gets nil-filled from the snapshot's top level (top-level stays untouched).
5. Never modify top-level `limits`/`account`/`state` (single-slot enrichment already handles the active account).
6. Sort: active first, then key order (matches `StatuslinePipeline` convention).

`duplicateOrgAccountKeys`: group `accounts` by non-nil `account?.organization`; any group with ≥2 members contributes all its member ids.

- [ ] **Step 1: Write the failing tests**

```swift
extension MultiAccountOAuthTests {
    private static func reading(
        key: String, label: String? = nil, email: String? = "\(UUID().uuidString)@x.com",
        org: String?, session: Double = 10, week: Double = 20, opus: Double? = 5
    ) -> OAuthAccountReading {
        OAuthAccountReading(
            accountKey: key, label: label ?? key, email: email, plan: "Max 5x",
            organizationId: org,
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: session, resetsAt: nil),
                currentWeekAllModels: LimitWindow(percentUsed: week, resetsAt: nil),
                currentWeekOpus: opus.map { LimitWindow(percentUsed: $0, resetsAt: nil) },
                extraUsage: nil),
            severity: .normal)
    }

    private static func statuslineSnapshot(accounts: [AccountUsage]?) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            parserVersion: "statusline-1.0", createdAt: Date(),
            source: SourceInfo(cliPath: "statusline", command: "bridge"),
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 50, resetsAt: nil),
                currentWeekAllModels: LimitWindow(percentUsed: 60, resetsAt: nil)),
            state: SnapshotState(status: .ok, severity: .normal),
            accounts: accounts)
    }

    @Test func mergeFillsExistingAccountGaps() {
        let existing = AccountUsage(
            id: "claude-work", label: "work",
            account: nil,
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: 42, resetsAt: nil),
                currentWeekAllModels: LimitWindow()),
            severity: .normal, isActive: false)
        let snap = Self.statuslineSnapshot(accounts: [existing])
        let merged = MultiAccountOAuth.merge(
            readings: [Self.reading(key: "claude-work", email: "w@x.com", org: "org-W", week: 88)],
            into: snap, now: Date())
        let acc = merged.accounts!.first { $0.id == "claude-work" }!
        // Statusline session (real data) wins; empty weekly filled from OAuth.
        #expect(acc.limits.currentSession?.percentUsed == 42)
        #expect(acc.limits.currentWeekAllModels?.percentUsed == 88)
        #expect(acc.limits.currentWeekOpus?.percentUsed == 5)
        #expect(acc.account?.email == "w@x.com")
        #expect(acc.account?.organization == "org-W")
        #expect(acc.account?.plan == "Max 5x")
    }

    @Test func mergeAppendsUnknownAccounts() {
        let snap = Self.statuslineSnapshot(accounts: [
            AccountUsage(
                id: "claude", label: "default", limits: LimitInfo(),
                severity: .normal, isActive: true)
        ])
        let merged = MultiAccountOAuth.merge(
            readings: [Self.reading(key: "claude-idle", org: "org-I")],
            into: snap, now: Date())
        let appended = merged.accounts!.first { $0.id == "claude-idle" }
        #expect(appended != nil)
        #expect(appended?.isActive == false)
        #expect(appended?.limits.currentSession?.percentUsed == 10)
    }

    @Test func mergeLeavesSingleAccountSnapshotUntouched() {
        let snap = Self.statuslineSnapshot(accounts: nil)
        let merged = MultiAccountOAuth.merge(
            readings: [Self.reading(key: "claude", org: "org-A")], into: snap, now: Date())
        #expect(merged.accounts == nil)          // byte-compat promise
        #expect(merged.limits == snap.limits)    // top level untouched
    }

    @Test func mergeBuildsAccountsListFromTwoReadings() {
        let snap = Self.statuslineSnapshot(accounts: nil)
        let merged = MultiAccountOAuth.merge(
            readings: [
                Self.reading(key: "claude", org: "org-A"),
                Self.reading(key: "claude-work", org: "org-W"),
            ],
            into: snap, now: Date())
        #expect(merged.accounts?.count == 2)
        #expect(merged.accounts?.first?.id == "claude")
        #expect(merged.accounts?.first?.isActive == true)
        #expect(merged.limits == snap.limits)
    }

    @Test func duplicateOrgDetection() {
        let a = AccountUsage(
            id: "claude", label: "default",
            account: AccountInfo(organization: "org-same"),
            limits: LimitInfo(), severity: .normal, isActive: true)
        let b = AccountUsage(
            id: "claude-copy", label: "copy",
            account: AccountInfo(organization: "org-same"),
            limits: LimitInfo(), severity: .normal, isActive: false)
        let c = AccountUsage(
            id: "claude-other", label: "other",
            account: AccountInfo(organization: "org-diff"),
            limits: LimitInfo(), severity: .normal, isActive: false)
        #expect(
            MultiAccountOAuth.duplicateOrgAccountKeys([a, b, c]) == ["claude", "claude-copy"])
        #expect(MultiAccountOAuth.duplicateOrgAccountKeys([a, c]).isEmpty)
    }
}
```

(Adjust `LimitInfo()`/`LimitWindow()` empty-inits to the real signatures in `Models.swift` — `LimitWindow()` exists per `OAuthPipeline.window(from:)`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeMeterCore --filter MultiAccountOAuthTests`
Expected: FAIL — `merge`/`duplicateOrgAccountKeys` not found

- [ ] **Step 3: Implement**

Append to `MultiAccountOAuth.swift`:

```swift
extension MultiAccountOAuth {

    /// Merges per-account OAuth readings into a snapshot's `accounts` list.
    /// Fill-only-missing: statusline data (near-real-time) wins on conflict;
    /// OAuth contributes what the statusline can't see (Opus weekly, extra
    /// usage, plan, email, org) and covers accounts with no live session.
    /// The snapshot's TOP-LEVEL fields are never modified here.
    public static func merge(
        readings: [OAuthAccountReading],
        into snapshot: ClaudeUsageSnapshot,
        now: Date
    ) -> ClaudeUsageSnapshot {
        guard !readings.isEmpty else { return snapshot }
        var byKey = Dictionary(uniqueKeysWithValues: readings.map { ($0.accountKey, $0) })
        var snap = snapshot

        if var accounts = snap.accounts, !accounts.isEmpty {
            for index in accounts.indices {
                guard let reading = byKey.removeValue(forKey: accounts[index].id) else {
                    continue
                }
                accounts[index] = filled(accounts[index], from: reading)
            }
            accounts.append(contentsOf: byKey.values.sorted { $0.accountKey < $1.accountKey }
                .map { newAccount(from: $0, now: now) })
            snap.accounts = sorted(accounts)
            return snap
        }

        // No accounts list: only materialize one for a real multi-account picture.
        guard readings.count >= 2 else { return snap }
        let activeKey = byKey["claude"] != nil ? "claude" : readings[0].accountKey
        let accounts = readings.map { reading in
            var account = newAccount(from: reading, now: now)
            account.isActive = reading.accountKey == activeKey
            return account
        }
        snap.accounts = sorted(accounts)
        return snap
    }

    /// Account keys that share an organization id with another account — two
    /// config dirs logged into the same login (their quota is one bucket shown
    /// twice).
    public static func duplicateOrgAccountKeys(_ accounts: [AccountUsage]) -> Set<String> {
        var byOrg: [String: [String]] = [:]
        for account in accounts {
            guard let org = account.account?.organization, !org.isEmpty else { continue }
            byOrg[org, default: []].append(account.id)
        }
        return Set(byOrg.values.filter { $0.count >= 2 }.flatMap { $0 })
    }

    private static func filled(_ existing: AccountUsage, from reading: OAuthAccountReading)
        -> AccountUsage
    {
        var account = existing
        var info = account.account ?? AccountInfo()
        if info.email == nil { info.email = reading.email }
        if info.plan == nil { info.plan = reading.plan }
        if info.organization == nil { info.organization = reading.organizationId }
        if info.loginMethod == nil { info.loginMethod = "OAuth" }
        account.account = info.isEmpty ? nil : info
        if account.limits.currentWeekOpus == nil {
            account.limits.currentWeekOpus = reading.limits.currentWeekOpus
        }
        if account.limits.extraUsage == nil {
            account.limits.extraUsage = reading.limits.extraUsage
        }
        if account.limits.currentSession?.percentUsed == nil {
            account.limits.currentSession = reading.limits.currentSession
        }
        if account.limits.currentWeekAllModels?.percentUsed == nil {
            account.limits.currentWeekAllModels = reading.limits.currentWeekAllModels
        }
        return account
    }

    private static func newAccount(from reading: OAuthAccountReading, now: Date) -> AccountUsage {
        AccountUsage(
            id: reading.accountKey,
            label: reading.label,
            account: AccountInfo(
                loginMethod: "OAuth",
                organization: reading.organizationId,
                email: reading.email,
                plan: reading.plan),
            limits: reading.limits,
            lastSuccessfulPollAt: now,
            severity: reading.severity,
            isActive: false)
    }

    private static func sorted(_ accounts: [AccountUsage]) -> [AccountUsage] {
        accounts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.id < rhs.id
        }
    }
}
```

(If `LimitInfo.currentSession` is non-optional in `Models.swift`, the two `percentUsed == nil` checks become direct `limits.currentSession.percentUsed == nil` — adjust to the real model.)

- [ ] **Step 4: Run tests**

Run: `swift test --package-path ClaudeMeterCore --filter MultiAccountOAuthTests` → PASS
Run: `swift test --package-path ClaudeMeterCore` → all green

- [ ] **Step 5: Commit**

```bash
git add ClaudeMeterCore/Sources/ClaudeMeterCore/MultiAccountOAuth.swift \
        ClaudeMeterCore/Tests/ClaudeMeterCoreTests/MultiAccountOAuthTests.swift
git commit -m "feat: merge per-account oauth readings into snapshot"
```

---

### Task 7: AppState wiring

**Files:**
- Modify: `ClaudeMeter/AppState.swift`

**Interfaces:**
- Consumes: `MultiAccountOAuth.fetchAll(...)` (Task 5), `MultiAccountOAuth.merge(readings:into:now:)` (Task 6), existing `oauthEnrichmentIntervalSeconds` (300 s, line ~75), `ConfigDirDiscovery.discover`, `AppGroupConfig.configuredConfigDirs`/`disabledAccountKeys`, `AppSettings.oauthSourceEnabled`, `Timeout.run`.

No new unit tests (app target has no test bundle; the logic is Core-tested). Verification is build + live run.

- [ ] **Step 1: Add state + fetch helper**

Near `cachedOAuthEnrichment` / `lastOAuthEnrichmentAt` declarations add:

```swift
    private var lastAccountsFetchAt: Date?
    private var cachedAccountReadings: [OAuthAccountReading] = []
```

Add a private method alongside `oauthEnrichment(for:now:)`:

```swift
    /// Per-account OAuth readings for every discovered config dir (multi-account
    /// tier). Interval-gated like the single-slot enrichment; runs off-main.
    /// Returns cached readings between refreshes so every poll can re-merge.
    private func accountReadings(now: Date) async -> [OAuthAccountReading] {
        guard AppSettings.oauthSourceEnabled else { return [] }
        if let lastAccountsFetchAt,
            now.timeIntervalSince(lastAccountsFetchAt) < Self.oauthEnrichmentIntervalSeconds
        {
            return cachedAccountReadings
        }
        lastAccountsFetchAt = now
        let configuredDirs = AppGroupConfig.configuredConfigDirs
        let disabledKeys = Set(AppGroupConfig.disabledAccountKeys)
        let thresholds = AppGroupConfig.currentThresholds()
        let readings = await Task.detached(priority: .utility) {
            let accounts = ConfigDirDiscovery.discover(
                configuredDirs: configuredDirs, disabledKeys: disabledKeys)
            return await MultiAccountOAuth.fetchAll(
                accounts: accounts,
                home: FileManager.default.homeDirectoryForCurrentUser,
                thresholds: thresholds,
                transport: ProviderHTTPClient.shared,
                credentialsLoader: { path, isDefault in
                    OAuthKeychain.loadResult(configDirPath: path, isDefault: isDefault)
                },
                now: now)
        }.value
        if !readings.isEmpty { cachedAccountReadings = readings }
        return cachedAccountReadings
    }
```

- [ ] **Step 2: Merge in `pollClaude`**

In `pollClaude`, directly after the existing enrichment application (`if let enrichment { Self.apply(enrichment, to: &snap) }`, ~line 475) and **before** the `writeLatest` decision, add:

```swift
                let readings = await accountReadings(now: now)
                let mergedSnap = MultiAccountOAuth.merge(readings: readings, into: snap, now: now)
                let accountsChanged = mergedSnap != snap
                snap = mergedSnap
```

and widen the persist condition:

```swift
                if !costResult.models.isEmpty || enrichment != nil || accountsChanged {
                    try? store.writeLatest(snap)
                }
```

`Timeout.run` already bounds the whole poll at 60 s? No — `pipeline.poll` is bounded; this runs after. `fetchAll` is sequential with the shared 10 s transport timeout per request and small N; acceptable without an extra timeout wrapper, but wrap defensively:

```swift
                let readings =
                    (try? await Timeout.run(seconds: 30) { await self.accountReadings(now: now) })
                    ?? []
```

Use whichever compiles cleanly with `Timeout.run`'s signature (it takes a throwing closure; a non-throwing async closure is fine).

- [ ] **Step 3: Build + test**

Run: `swift test --package-path ClaudeMeterCore` → green
Run: `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED
Watch for Swift 6 capture errors in the `Task.detached` (all captured values are `Sendable` value types + `ProviderHTTPClient.shared` which is already `Sendable`).

- [ ] **Step 4: Commit**

```bash
git add ClaudeMeter/AppState.swift
git commit -m "feat: merge multi-account oauth readings each poll"
```

---

### Task 8: Popover duplicate badge

**Files:**
- Modify: `ClaudeMeter/PopoverView.swift` (`accountModels(_:)` ~line 220, `AccountCardModel` — find its definition via `grep -n "struct AccountCardModel" ClaudeMeter/*.swift`)
- Modify: the card views rendering `AccountCardModel` (`AccountRingCard`/`AccountBarCard` in `ClaudeMeter/PlayfulComponents.swift`)

- [ ] **Step 1: Extend the model**

Add `var isDuplicateLogin: Bool = false` to `AccountCardModel`.

In `PopoverView.accountModels(_:)`, before mapping:

```swift
            let duplicates = MultiAccountOAuth.duplicateOrgAccountKeys(accounts)
```

and in the `AccountCardModel(...)` construction add `isDuplicateLogin: duplicates.contains(acc.id)`.

- [ ] **Step 2: Render the badge**

In `AccountRingCard` and `AccountBarCard` (PlayfulComponents.swift), next to the plan chip / account label, add:

```swift
                if model.isDuplicateLogin {
                    Text("same login")
                        .font(PFont.body(9, .bold))
                        .foregroundStyle(Color.pfInkMuted)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.pfTrack))
                        .help("Two config dirs are logged into the same Claude account — they share one quota.")
                }
```

Match the exact chip styling used by the existing "paused" chip in `extraUsageCard` (font/colors above copied from it).

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add ClaudeMeter/PopoverView.swift ClaudeMeter/PlayfulComponents.swift
git commit -m "feat: duplicate-login badge on account cards"
```

---

### Task 9: Docs + known-gaps update

**Files:**
- Modify: `AGENTS.md` (multi-account section + Known gaps), `SPECS.md` (if it has a data-sources section — check `grep -n "OAuth" SPECS.md`)

- [ ] **Step 1: Update AGENTS.md**

- In the OAuth section, add a paragraph: multi-account OAuth reads (per-config-dir Keychain service `Claude Code-credentials-<first 8 hex sha256(dir path)>`, legacy unsuffixed for `~/.claude`; identity from `<dir>/.claude.json`, home-root `~/.claude.json` for default; fill-only-missing merge, statusline wins on fresh windows; no per-account token refresh — expired secondary tokens degrade to statusline-only; 429 aborts the remaining accounts via the shared backoff).
- Known gaps: rewrite "Multi-account is statusline-only …" to reflect the remaining gaps only (per-account notifications still diff statusline accounts; secondary-account tokens are not refreshed; symlinked config dirs may miss the hashed Keychain entry).
- Mention `AuthEnv` scrub under the Codex section.

- [ ] **Step 2: Verify full suite one last time**

Run: `swift test --package-path ClaudeMeterCore && xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO`
Expected: green + BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md SPECS.md
git commit -m "docs: multi-account oauth notes and gap updates"
```

---

## Self-Review Notes

- **Spec coverage:** #1 per-account usage (Tasks 3+5+7), #2 identity (Task 4, local-file variant — `claude auth status` subprocess consciously dropped, see Non-goals), #3 duplicate detection (Tasks 6+8), #5 env scrub (Task 1). Plan-tier naming (Task 2) supports #2's plan display.
- **Model-signature caveats:** Tasks 5/6 flag the `LimitInfo`/`LimitWindow` initializer shapes — the implementer must reconcile against `Models.swift` before writing the tests (the plan's test code compiles only against the real signatures).
- **Widget/current.json compat:** merge only fills `accounts[]` fields that already exist in the schema; single-account snapshots keep `accounts == nil` unless ≥2 OAuth readings exist (a genuine multi-account machine).
- **Notifications:** `NotificationPolicy.triggers` diffs per-account by id — appended OAuth-only accounts gain baselines automatically on the second merge-poll; no change needed.
