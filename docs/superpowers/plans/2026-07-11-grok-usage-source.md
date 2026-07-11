# Grok Usage Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Grok (xAI Grok Build CLI) usage card to Claude Meter, mirroring the existing Codex/Cursor provider pattern.

**Architecture:** Three new files in the `ClaudeMeterCore` Swift package (auth reader, usage model + response decoder, HTTP provider), plus edits to `AppState`, `PopoverView`, `SettingsView`, `DiagnosticsView` in the app target. Reads the bearer token from `~/.grok/auth.json` and calls `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`. No token refresh (the CLI owns it). No menu bar / widget / notification integration.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing (`@Test`/`#expect`), existing `HTTPTransport`/`ProviderHTTPClient` infrastructure.

**Spec:** `docs/superpowers/specs/2026-07-11-grok-usage-source-design.md`

## Global Constraints

- Core package (`ClaudeMeterCore`) must not import AppKit/SwiftUI.
- `DateFormatter`/`ISO8601DateFormatter` are not `Sendable` — create per call.
- All provider HTTP through injected `HTTPTransport` (default `ProviderHTTPClient.shared`).
- All user-visible error strings pass through `DiagnosticsSanitizer.sanitize` at the AppState boundary.
- New Core files need **no** `project.pbxproj` entries (SwiftPM). This plan adds no new app-target files.
- Grok timestamps carry **microsecond** fractions (`2026-07-04T05:57:34.172321+00:00`). `ISO8601DateFormatter` with `.withFractionalSeconds` requires exactly 3 fractional digits and rejects them — strip the fraction before parsing.
- Proto3 backend omits zero-valued fields: absent `creditUsagePercent` with a present `currentPeriod` means **0% used**, not unknown.
- Verify Core after each Core task: `swift test --package-path ClaudeMeterCore`
- Verify app compiles after app-target tasks: `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO`

---

### Task 1: GrokUsage model + billing response decoding

**Files:**
- Create: `ClaudeMeterCore/Sources/ClaudeMeterCore/GrokUsage.swift`
- Test: `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/GrokUsageTests.swift`

**Interfaces:**
- Produces: `GrokUsage` (public struct: `usedPercent: Double`, `windowLabel: String`, `periodStart: Date?`, `resetsAt: Date?`, `onDemandUsedCents: Int`, `onDemandCapCents: Int`, `prepaidBalanceCents: Int`, `accountEmail: String?`, `maskedAccountEmail: String?`, `updatedAt: Date`; computed `energyLeftPercent: Double`, `cardDisplayPercent: Double`), `GrokUsageError` (`loginRequired`, `httpError(Int)`, `malformedResponse`), `GrokBillingResponse: Decodable` with `usage(accountEmail:now:) throws -> GrokUsage`, and `GrokTimestamp.parse(_ raw: String) -> Date?`.

- [ ] **Step 1: Write the failing tests**

Create `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/GrokUsageTests.swift`:

```swift
import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("Grok usage")
struct GrokUsageTests {

    /// Live fixture captured 2026-07-11 from cli-chat-proxy.grok.com (grok 0.2.93).
    static let liveFixture = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-04T05:57:34.172321+00:00","end":"2026-07-11T05:57:34.172321+00:00"},"creditUsagePercent":36.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"productUsage":[{"product":"GrokBuild","usagePercent":36.0}],"isUnifiedBillingUser":true,"prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD","billingPeriodStart":"2026-07-04T05:57:34.172321+00:00","billingPeriodEnd":"2026-07-11T05:57:34.172321+00:00"}}
        """

    @Test func decodesLiveBillingFixture() throws {
        let response = try JSONDecoder().decode(
            GrokBillingResponse.self, from: Data(Self.liveFixture.utf8))
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let usage = try response.usage(accountEmail: "alpha@example.com", now: now)

        #expect(usage.usedPercent == 36.0)
        #expect(usage.energyLeftPercent == 64.0)
        #expect(usage.windowLabel == "Weekly")
        #expect(usage.onDemandUsedCents == 0)
        #expect(usage.prepaidBalanceCents == 0)
        #expect(usage.maskedAccountEmail == "a***@example.com")
        // 2026-07-11T05:57:34Z (fraction stripped, second precision).
        #expect(usage.resetsAt == Date(timeIntervalSince1970: 1_783_749_454))
        #expect(usage.updatedAt == now)
    }

    /// Proto3 omits zero-valued fields: no creditUsagePercent + present period = 0% used.
    @Test func absentPercentWithPresentPeriodMeansZeroUsed() throws {
        let json = """
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-04T05:57:34.172321+00:00","end":"2026-07-11T05:57:34.172321+00:00"},"onDemandCap":{"val":0},"isUnifiedBillingUser":true}}
            """
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: Data(json.utf8))
        let usage = try response.usage(accountEmail: nil, now: Date(timeIntervalSince1970: 0))

        #expect(usage.usedPercent == 0)
        #expect(usage.energyLeftPercent == 100)
    }

    @Test func missingPeriodThrowsMalformed() throws {
        let response = try JSONDecoder().decode(
            GrokBillingResponse.self, from: Data(#"{"config":{}}"#.utf8))
        #expect(throws: GrokUsageError.malformedResponse) {
            try response.usage(accountEmail: nil, now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func mapsOnDemandMinorUnits() throws {
        let json = """
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-07-01T00:00:00+00:00","end":"2026-08-01T00:00:00+00:00"},"creditUsagePercent":12.5,"onDemandCap":{"val":1000},"onDemandUsed":{"val":42},"prepaidBalance":{"val":250}}}
            """
        let response = try JSONDecoder().decode(GrokBillingResponse.self, from: Data(json.utf8))
        let usage = try response.usage(accountEmail: nil, now: Date(timeIntervalSince1970: 0))

        #expect(usage.windowLabel == "Monthly")
        #expect(usage.onDemandUsedCents == 42)
        #expect(usage.onDemandCapCents == 1000)
        #expect(usage.prepaidBalanceCents == 250)
    }

    @Test func parsesMicrosecondAndPlainTimestamps() {
        // Microsecond fraction (ISO8601DateFormatter.withFractionalSeconds rejects >3 digits).
        #expect(
            GrokTimestamp.parse("2026-07-04T05:57:34.172321+00:00")
                == Date(timeIntervalSince1970: 1_783_144_654))
        #expect(
            GrokTimestamp.parse("2026-07-04T05:57:34Z")
                == Date(timeIntervalSince1970: 1_783_144_654))
        #expect(GrokTimestamp.parse("not-a-date") == nil)
    }

    @Test func percentClampsForDisplay() {
        let usage = GrokUsage(
            usedPercent: 120, windowLabel: "Weekly", periodStart: nil, resetsAt: nil,
            onDemandUsedCents: 0, onDemandCapCents: 0, prepaidBalanceCents: 0,
            accountEmail: nil, updatedAt: Date(timeIntervalSince1970: 0))
        #expect(usage.energyLeftPercent == 0)
        #expect(usage.cardDisplayPercent == 100)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeMeterCore --filter GrokUsageTests`
Expected: compile FAILURE — `GrokBillingResponse`, `GrokUsage`, `GrokTimestamp` not defined.

- [ ] **Step 3: Write the implementation**

Create `ClaudeMeterCore/Sources/ClaudeMeterCore/GrokUsage.swift`:

```swift
import Foundation

/// Weekly (or monthly) Grok Build credit usage for the signed-in subscriber.
/// Sourced from the unofficial cli-chat-proxy billing endpoint — the same
/// upstream call the Grok CLI's own `/usage` command makes. May break without
/// notice (same caveat as Cursor's api2.cursor.sh).
public struct GrokUsage: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var windowLabel: String
    public var periodStart: Date?
    public var resetsAt: Date?
    /// Monetary fields are integer minor units (cents).
    public var onDemandUsedCents: Int
    public var onDemandCapCents: Int
    public var prepaidBalanceCents: Int
    public var accountEmail: String?
    public var maskedAccountEmail: String?
    public var updatedAt: Date

    public init(
        usedPercent: Double,
        windowLabel: String,
        periodStart: Date?,
        resetsAt: Date?,
        onDemandUsedCents: Int,
        onDemandCapCents: Int,
        prepaidBalanceCents: Int,
        accountEmail: String?,
        updatedAt: Date
    ) {
        self.usedPercent = usedPercent
        self.windowLabel = windowLabel
        self.periodStart = periodStart
        self.resetsAt = resetsAt
        self.onDemandUsedCents = onDemandUsedCents
        self.onDemandCapCents = onDemandCapCents
        self.prepaidBalanceCents = prepaidBalanceCents
        self.accountEmail = accountEmail
        self.maskedAccountEmail = accountEmail.map(CodexUsage.maskedEmail)
        self.updatedAt = updatedAt
    }

    public var energyLeftPercent: Double { min(100, max(0, 100 - usedPercent)) }
    public var cardDisplayPercent: Double { min(100, max(0, usedPercent)) }
}

public enum GrokUsageError: Error, LocalizedError, Equatable {
    case loginRequired
    case httpError(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .loginRequired: "Grok sign-in required. Open Grok Build and run `grok login`."
        case let .httpError(code): "Grok usage request failed (HTTP \(code))."
        case .malformedResponse: "Grok billing returned an unexpected response."
        }
    }
}

public struct GrokBillingResponse: Decodable, Sendable {
    let config: Config

    struct Config: Decodable, Sendable {
        let currentPeriod: Period?
        let creditUsagePercent: Double?
        let onDemandCap: MoneyValue?
        let onDemandUsed: MoneyValue?
        let prepaidBalance: MoneyValue?
    }

    struct Period: Decodable, Sendable {
        let type: String?
        let start: String?
        let end: String?
    }

    /// `{ "val": <minor units> }` wrapper; proto3 omits zero so `val` may be absent.
    struct MoneyValue: Decodable, Sendable {
        let val: Int?
    }

    public func usage(accountEmail: String?, now: Date) throws -> GrokUsage {
        guard let period = config.currentPeriod else {
            throw GrokUsageError.malformedResponse
        }
        // Proto3 omits zero fields: present period + absent percent = 0% used.
        return GrokUsage(
            usedPercent: config.creditUsagePercent ?? 0,
            windowLabel: Self.label(forPeriodType: period.type),
            periodStart: period.start.flatMap(GrokTimestamp.parse),
            resetsAt: period.end.flatMap(GrokTimestamp.parse),
            onDemandUsedCents: config.onDemandUsed?.val ?? 0,
            onDemandCapCents: config.onDemandCap?.val ?? 0,
            prepaidBalanceCents: config.prepaidBalance?.val ?? 0,
            accountEmail: accountEmail,
            updatedAt: now)
    }

    static func label(forPeriodType type: String?) -> String {
        switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY": "Weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY": "Monthly"
        default: "Credits"
        }
    }
}

enum GrokTimestamp {
    /// Grok emits microsecond fractions ("…:34.172321+00:00"), which
    /// ISO8601DateFormatter's `.withFractionalSeconds` (exactly 3 digits)
    /// rejects — strip the fraction and parse at second precision.
    static func parse(_ raw: String) -> Date? {
        let stripped = raw.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stripped)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeMeterCore --filter GrokUsageTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Run the full Core suite**

Run: `swift test --package-path ClaudeMeterCore`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add ClaudeMeterCore/Sources/ClaudeMeterCore/GrokUsage.swift ClaudeMeterCore/Tests/ClaudeMeterCoreTests/GrokUsageTests.swift
git commit -m "feat: add Grok usage model and billing response decoding"
```

---

### Task 2: GrokAuthStore — read `~/.grok/auth.json`

**Files:**
- Create: `ClaudeMeterCore/Sources/ClaudeMeterCore/GrokAuth.swift`
- Test: `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/GrokAuthTests.swift`

**Interfaces:**
- Produces: `GrokCredentials` (public struct: `bearer: String`, `email: String?`, `expiresAt: Date?`), `GrokAuthError` (`missing`, `loginRequired`, `unreadable`), `GrokAuthStore.load(authPath:now:) throws -> GrokCredentials`, `GrokAuthStore.defaultAuthPath() -> URL`.
- Consumes: `GrokTimestamp.parse` from Task 1.

- [ ] **Step 1: Write the failing tests**

Create `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/GrokAuthTests.swift`:

```swift
import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("Grok auth")
struct GrokAuthTests {

    private func writeAuth(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func loadsOIDCEntry() throws {
        let url = try writeAuth("""
            {"https://auth.x.ai::client-uuid":{"key":"bearer-token","auth_mode":"oidc","email":"alpha@example.com","expires_at":"2026-07-11T06:43:07.251431Z","refresh_token":"r"}}
            """)
        let creds = try GrokAuthStore.load(
            authPath: url, now: Date(timeIntervalSince1970: 1_783_140_000))

        #expect(creds.bearer == "bearer-token")
        #expect(creds.email == "alpha@example.com")
        #expect(creds.expiresAt != nil)
    }

    /// The auth.x.ai OIDC entry (SuperGrok/X Premium) wins over the legacy
    /// accounts.x.ai session entry.
    @Test func prefersAuthXaiOverLegacyEntry() throws {
        let url = try writeAuth("""
            {"https://accounts.x.ai/sign-in":{"key":"legacy-token"},
             "https://auth.x.ai::client-uuid":{"key":"oidc-token","expires_at":"2099-01-01T00:00:00Z"}}
            """)
        let creds = try GrokAuthStore.load(
            authPath: url, now: Date(timeIntervalSince1970: 1_783_140_000))

        #expect(creds.bearer == "oidc-token")
    }

    @Test func expiredTokenThrowsLoginRequired() throws {
        let url = try writeAuth("""
            {"https://auth.x.ai::client-uuid":{"key":"bearer-token","expires_at":"2026-07-11T06:43:07.251431Z"}}
            """)
        // Now is after expires_at.
        #expect(throws: GrokAuthError.loginRequired) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 1_900_000_000))
        }
    }

    @Test func missingFileThrowsMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-tests-\(UUID().uuidString)/auth.json")
        #expect(throws: GrokAuthError.missing) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func malformedJSONThrowsUnreadable() throws {
        let url = try writeAuth("not json")
        #expect(throws: GrokAuthError.unreadable) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func entryWithoutKeyThrowsMissing() throws {
        let url = try writeAuth(#"{"https://auth.x.ai::client-uuid":{"auth_mode":"oidc"}}"#)
        #expect(throws: GrokAuthError.missing) {
            try GrokAuthStore.load(authPath: url, now: Date(timeIntervalSince1970: 0))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeMeterCore --filter GrokAuthTests`
Expected: compile FAILURE — `GrokAuthStore`, `GrokCredentials`, `GrokAuthError` not defined.

- [ ] **Step 3: Write the implementation**

Create `ClaudeMeterCore/Sources/ClaudeMeterCore/GrokAuth.swift`:

```swift
import Foundation

public struct GrokCredentials: Equatable, Sendable {
    public var bearer: String
    public var email: String?
    public var expiresAt: Date?

    public init(bearer: String, email: String?, expiresAt: Date?) {
        self.bearer = bearer
        self.email = email
        self.expiresAt = expiresAt
    }
}

public enum GrokAuthError: Error, LocalizedError, Equatable {
    case missing
    case loginRequired
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .missing: "Grok Build CLI not signed in. Install grok and run `grok login`."
        case .loginRequired: "Grok sign-in expired. Open Grok Build to refresh it."
        case .unreadable: "Couldn't read Grok credentials (auth.json)."
        }
    }
}

/// Reads the Grok Build CLI's cached OIDC credential. The CLI owns refresh —
/// we never refresh and never write back; an expired token maps to
/// `.loginRequired` and is never sent.
public enum GrokAuthStore {
    public static func defaultAuthPath() -> URL {
        let env = ProcessInfo.processInfo.environment["GROK_HOME"]
        let root = env.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        return root.appendingPathComponent("auth.json")
    }

    public static func load(
        authPath: URL = defaultAuthPath(),
        now: Date = Date()
    ) throws -> GrokCredentials {
        guard FileManager.default.fileExists(atPath: authPath.path) else {
            throw GrokAuthError.missing
        }
        guard let data = try? Data(contentsOf: authPath),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw GrokAuthError.unreadable }

        guard let entry = preferredEntry(in: object),
            let key = entry["key"] as? String, !key.isEmpty
        else { throw GrokAuthError.missing }

        let expiresAt = (entry["expires_at"] as? String).flatMap(GrokTimestamp.parse)
        if let expiresAt, expiresAt <= now { throw GrokAuthError.loginRequired }
        return GrokCredentials(
            bearer: key,
            email: entry["email"] as? String,
            expiresAt: expiresAt)
    }

    /// Top-level keys are OIDC scope identifiers. Prefer the auth.x.ai OIDC
    /// entry (SuperGrok/X Premium) over the legacy accounts.x.ai session.
    static func preferredEntry(in object: [String: Any]) -> [String: Any]? {
        let entries = object.compactMapValues { $0 as? [String: Any] }
        if let oidc = entries.first(where: { $0.key.hasPrefix("https://auth.x.ai") })?.value {
            return oidc
        }
        if let legacy = entries["https://accounts.x.ai/sign-in"] { return legacy }
        return entries.values.first
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeMeterCore --filter GrokAuthTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeMeterCore/Sources/ClaudeMeterCore/GrokAuth.swift ClaudeMeterCore/Tests/ClaudeMeterCoreTests/GrokAuthTests.swift
git commit -m "feat: read Grok Build CLI credentials from ~/.grok/auth.json"
```

---

### Task 3: GrokUsageProvider — billing HTTP fetch

**Files:**
- Create: `ClaudeMeterCore/Sources/ClaudeMeterCore/GrokUsageProvider.swift`
- Test: append to `ClaudeMeterCore/Tests/ClaudeMeterCoreTests/GrokUsageTests.swift`

**Interfaces:**
- Consumes: `GrokAuthStore.load` (Task 2), `GrokBillingResponse`/`GrokUsage`/`GrokUsageError` (Task 1), `HTTPTransport`/`ProviderHTTPClient.shared`/`HTTPRetryPolicy` (existing, `ProviderHTTP.swift`).
- Produces: `GrokUsageProvider` (`init(transport:credentialsLoader:)`, `fetchUsage(now:) async throws -> GrokUsage`, `isAvailable() async -> Bool`).

- [ ] **Step 1: Write the failing tests**

Append to `GrokUsageTests.swift` inside the `GrokUsageTests` suite:

```swift
    @Test func providerSendsBearerAndDecodesUsage() async throws {
        let transport = RecordingGrokTransport(data: Data(Self.liveFixture.utf8), status: 200)
        let provider = GrokUsageProvider(
            transport: transport,
            credentialsLoader: { _ in
                GrokCredentials(bearer: "bearer-token", email: "alpha@example.com", expiresAt: nil)
            })
        let usage = try await provider.fetchUsage(now: Date(timeIntervalSince1970: 1_783_000_000))

        #expect(usage.usedPercent == 36.0)
        #expect(usage.accountEmail == "alpha@example.com")
        #expect(
            transport.lastRequest?.url?.absoluteString
                == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        #expect(
            transport.lastRequest?.value(forHTTPHeaderField: "Authorization")
                == "Bearer bearer-token")
    }

    @Test func providerMapsUnauthorizedToLoginRequired() async {
        let transport = RecordingGrokTransport(data: Data(), status: 401)
        let provider = GrokUsageProvider(
            transport: transport,
            credentialsLoader: { _ in GrokCredentials(bearer: "t", email: nil, expiresAt: nil) })
        await #expect(throws: GrokUsageError.loginRequired) {
            try await provider.fetchUsage(now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func providerMapsServerErrorToHTTPError() async {
        let transport = RecordingGrokTransport(data: Data(), status: 503)
        let provider = GrokUsageProvider(
            transport: transport,
            credentialsLoader: { _ in GrokCredentials(bearer: "t", email: nil, expiresAt: nil) })
        await #expect(throws: GrokUsageError.httpError(503)) {
            try await provider.fetchUsage(now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func providerPropagatesCredentialFailureWithoutNetwork() async {
        let transport = RecordingGrokTransport(data: Data(), status: 200)
        let provider = GrokUsageProvider(
            transport: transport,
            credentialsLoader: { _ in throw GrokAuthError.loginRequired })
        await #expect(throws: GrokAuthError.loginRequired) {
            try await provider.fetchUsage(now: Date(timeIntervalSince1970: 0))
        }
        #expect(transport.lastRequest == nil)
    }
```

And at file scope (below the suite), the stub transport (mirrors `RecordingTransport` in `CodexUsageTests.swift`):

```swift
private final class RecordingGrokTransport: HTTPTransport, @unchecked Sendable {
    let data: Data
    let status: Int
    var lastRequest: URLRequest?

    init(data: Data, status: Int) {
        self.data = data
        self.status = status
    }

    func send(_ request: URLRequest, retry _: HTTPRetryPolicy) async throws
        -> (Data, HTTPURLResponse)
    {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeMeterCore --filter GrokUsageTests`
Expected: compile FAILURE — `GrokUsageProvider` not defined.

- [ ] **Step 3: Write the implementation**

Create `ClaudeMeterCore/Sources/ClaudeMeterCore/GrokUsageProvider.swift`:

```swift
import Foundation

/// Fetches Grok Build credit usage from the unofficial cli-chat-proxy billing
/// endpoint using the CLI's cached bearer token. Read-only: never refreshes or
/// writes credentials. 401/403 means the token expired or was revoked — the
/// CLI refreshes it the next time the user runs `grok`.
public final class GrokUsageProvider: @unchecked Sendable {
    private static let billingURL = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    private let transport: any HTTPTransport
    private let credentialsLoader: @Sendable (Date) throws -> GrokCredentials

    public init(
        transport: any HTTPTransport = ProviderHTTPClient.shared,
        credentialsLoader: @escaping @Sendable (Date) throws -> GrokCredentials = { now in
            try GrokAuthStore.load(now: now)
        }
    ) {
        self.transport = transport
        self.credentialsLoader = credentialsLoader
    }

    public func isAvailable() async -> Bool {
        (try? credentialsLoader(Date())) != nil
    }

    public func fetchUsage(now: Date = Date()) async throws -> GrokUsage {
        let credentials = try credentialsLoader(now)
        var request = URLRequest(url: Self.billingURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeMeter", forHTTPHeaderField: "User-Agent")

        let (data, http) = try await transport.send(request, retry: .transient)
        switch http.statusCode {
        case 200...299:
            let response = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
            return try response.usage(accountEmail: credentials.email, now: now)
        case 401, 403:
            throw GrokUsageError.loginRequired
        default:
            throw GrokUsageError.httpError(http.statusCode)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeMeterCore --filter GrokUsageTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Run the full Core suite**

Run: `swift test --package-path ClaudeMeterCore`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add ClaudeMeterCore/Sources/ClaudeMeterCore/GrokUsageProvider.swift ClaudeMeterCore/Tests/ClaudeMeterCoreTests/GrokUsageTests.swift
git commit -m "feat: add Grok usage provider (cli-chat-proxy billing endpoint)"
```

---

### Task 4: AppState + AppSettings wiring

**Files:**
- Modify: `ClaudeMeter/AppState.swift` (published state near line 28, provider near line 40, staleness near line 271, toggle helpers near line 297, poll group near line 439, poll method near line 546, AppSettings near line 924, `hasEnabledDataSource` near line 1001 — line numbers pre-plan, shift as edits land)

**Interfaces:**
- Consumes: `GrokUsageProvider.fetchUsage(now:)`, `GrokUsage` (Tasks 1–3).
- Produces (used by Tasks 5–6): `AppState.grokUsage: GrokUsage?`, `AppState.grokError: String?`, `AppState.grokLastPolledAt: Date?`, `AppState.grokIsStale: Bool`, `AppState.setGrokSourceEnabled(_:)`, `AppState.clearGrokState()`, `AppSettings.grokSourceEnabledKey` (= `"grokSourceEnabled"`), `AppSettings.grokSourceEnabled: Bool` (default false).

Every addition mirrors the existing Codex code exactly, minus the mode picker. All snippets below are additions; anchor text quoted from the current file.

- [ ] **Step 1: Add published state** — next to the `codexUsage` block (~line 28):

```swift
    @Published var grokUsage: GrokUsage? = nil
    @Published var grokError: String? = nil
    @Published var grokLastPolledAt: Date? = nil
```

- [ ] **Step 2: Add provider** — next to `private let codexProvider = CodexUsageProvider()`:

```swift
    private let grokProvider = GrokUsageProvider()
```

- [ ] **Step 3: Add staleness** — next to `codexIsStale`:

```swift
    var grokIsStale: Bool {
        AppGroupConfig.isSnapshotStale(lastPollAt: grokLastPolledAt)
    }
```

- [ ] **Step 4: Add toggle + clear helpers** — after `clearCodexState()`:

```swift
    func setGrokSourceEnabled(_ enabled: Bool) {
        hasEnabledDataSource = AppSettings.hasEnabledDataSource
        if enabled {
            if isActive { startPolling() }
        } else {
            pipelineGeneration += 1
            clearGrokState()
            if canPoll {
                // Claude/Cursor/Codex sources may still be enabled.
            } else {
                stopPolling()
                isLoading = false
            }
        }
    }

    func clearGrokState() {
        grokUsage = nil
        grokError = nil
        grokLastPolledAt = nil
    }
```

- [ ] **Step 5: Add to the poll task group** — inside `withTaskGroup` after the `codexSourceEnabled` block:

```swift
            if AppSettings.grokSourceEnabled {
                group.addTask { await self.pollGrok(generation: generation) }
            }
```

- [ ] **Step 6: Add the poll method** — after `pollCodex(generation:)`:

```swift
    /// Grok runs independently of Claude, Cursor, and Codex so failures never
    /// affect Claude state, menu-bar severity, widget data, or notifications.
    private func pollGrok(generation: Int) async {
        let provider = grokProvider
        let now = Date()
        do {
            let usage = try await Timeout.run(seconds: Self.pollTimeoutSeconds) {
                try await provider.fetchUsage(now: now)
            }
            guard generation == pipelineGeneration,
                canPoll,
                AppSettings.grokSourceEnabled
            else { return }
            grokUsage = usage
            grokError = nil
            grokLastPolledAt = Date()
        } catch {
            guard generation == pipelineGeneration,
                canPoll,
                AppSettings.grokSourceEnabled
            else { return }
            grokError = DiagnosticsSanitizer.sanitize(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
```

- [ ] **Step 7: Add AppSettings key + accessor** — next to `codexSourceEnabledKey` / `codexSourceEnabled`:

```swift
    static let grokSourceEnabledKey = "grokSourceEnabled"
```

```swift
    /// Grok defaults off — it is a separate provider card like Cursor and Codex.
    static var grokSourceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: grokSourceEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: grokSourceEnabledKey) }
    }
```

- [ ] **Step 8: Extend `hasEnabledDataSource`** — change:

```swift
        hasClaudeSource || cursorSourceEnabled || codexSourceEnabled
```

to:

```swift
        hasClaudeSource || cursorSourceEnabled || codexSourceEnabled || grokSourceEnabled
```

- [ ] **Step 9: Compile check**

Run: `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 10: Commit**

```bash
git add ClaudeMeter/AppState.swift
git commit -m "feat: wire Grok usage polling into AppState"
```

---

### Task 5: Popover Grok card

**Files:**
- Modify: `ClaudeMeter/PopoverView.swift` (source flags ~line 10, `hasContent` ~line 102, error-state chain ~line 126, `dataState` card list ~line 159, card implementations after the Codex card ~line 695, error states ~line 797, `loadingMessage` ~line 755)

**Interfaces:**
- Consumes: `AppState.grokUsage/grokError/grokIsStale`, `GrokUsage` fields (`cardDisplayPercent`, `usedPercent`, `windowLabel`, `resetsAt`, `onDemandUsedCents`, `onDemandCapCents`), `AppSettings.grokSourceEnabledKey`, existing `EnergyBand`/`EnergyBar`/`noticeBanner`/`statusState`/`chunkyCard`/`PFont` helpers.

- [ ] **Step 1: Add the storage flag** — next to the `codexSourceEnabled` `@AppStorage`:

```swift
    @AppStorage(AppSettings.grokSourceEnabledKey) private var grokSourceEnabled = false
```

- [ ] **Step 2: Extend content gates** — next to `hasCodex` add:

```swift
    private var hasGrok: Bool {
        grokSourceEnabled && appState.grokUsage != nil
    }
```

Change `appState.snapshot != nil || hasCursor || hasCodex` to:

```swift
        appState.snapshot != nil || hasCursor || hasCodex || hasGrok
```

- [ ] **Step 3: Extend the error-state chain** — after the `codexErrorState` branch (`} else if codexSourceEnabled && appState.codexError != nil {`):

```swift
        } else if grokSourceEnabled && appState.grokError != nil {
            grokErrorState
```

- [ ] **Step 4: Add the card to `dataState`** — after the `hasCodex` block:

```swift
            if hasGrok, let grok = appState.grokUsage {
                grokNotices()
                grokCard(grok)
            }
```

- [ ] **Step 5: Add card implementations** — after `codexCreditsFormatter`, mirroring the Codex card:

```swift
    // MARK: - Grok card (usage-based, local to the popover)

    @ViewBuilder
    private func grokNotices() -> some View {
        if appState.grokError != nil {
            noticeBanner(
                appState.grokError ?? "Grok refresh failed — showing last known data",
                systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        } else if appState.grokIsStale {
            noticeBanner("Grok data may be outdated", systemImage: "clock.fill", tint: .pfInkMuted)
        }
    }

    private func grokCard(_ usage: GrokUsage) -> some View {
        let band = EnergyBand(severity: usageThresholds.severity(for: usage.usedPercent))
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "atom")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                Text("Grok")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                Spacer()
                Text("\(Int(usage.cardDisplayPercent.rounded()))%")
                    .font(PFont.display(14, .bold))
                    .foregroundStyle(band == .full ? Color.pfInk : tint)
                    .monospacedDigit()
            }
            EnergyBar(fraction: usage.cardDisplayPercent / 100, color: tint, height: 12)
            if let subtitle = grokSubtitle(usage) {
                Text(subtitle)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func grokSubtitle(_ usage: GrokUsage) -> String? {
        var parts: [String] = [usage.windowLabel]
        if usage.onDemandUsedCents > 0 {
            let used = Double(usage.onDemandUsedCents) / 100
            if usage.onDemandCapCents > 0 {
                let cap = Double(usage.onDemandCapCents) / 100
                parts.append(String(format: "On-demand $%.2f of $%.2f", used, cap))
            } else {
                parts.append(String(format: "On-demand $%.2f", used))
            }
        }
        if let reset = usage.resetsAt, reset > now {
            parts.append("Resets \(Self.codexDateFormatter.string(from: reset))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
```

- [ ] **Step 6: Add the error state** — after `codexErrorState`:

```swift
    private var grokErrorState: some View {
        statusState(
            emoji: "⚠️", title: "Couldn't read Grok",
            message: appState.grokError ?? "Install Grok Build or run `grok login`.",
            primaryTitle: "Open Settings", primary: openSettingsAndCompleteOnboarding)
    }
```

- [ ] **Step 7: Update `loadingMessage`** — inspect the existing chain (single-source special cases per provider) and add the Grok-only case following the same shape as the Codex-only branch, e.g.:

```swift
        if grokSourceEnabled && !AppSettings.hasClaudeSource && !cursorSourceEnabled
            && !codexSourceEnabled
        {
            return "Warming up Grok…"
        }
```

- [ ] **Step 8: Compile check**

Run: `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add ClaudeMeter/PopoverView.swift
git commit -m "feat: add Grok card to popover"
```

---

### Task 6: Settings toggle + Diagnostics + CHANGELOG

**Files:**
- Modify: `ClaudeMeter/SettingsView.swift` (storage flags ~line 419, status state ~line 425, card list after the Codex `DataSourceCard` ~line 485, `onChange` handlers ~line 499, content/status helpers after `loadCodexStatus` ~line 630)
- Modify: `ClaudeMeter/DiagnosticsView.swift` (sources section ~line 61, poll section ~line 94, poll-time helper ~line 149)
- Modify: `CHANGELOG.md` (new unreleased entry at top)

**Interfaces:**
- Consumes: `AppState.setGrokSourceEnabled(_:)`, `AppState.grokError/grokUsage/grokLastPolledAt`, `AppSettings.grokSourceEnabledKey`/`grokSourceEnabled`, `GrokAuthStore.load()`, `GrokAuthError`, `CodexUsage.maskedEmail` (existing static), `DiagnosticsSanitizer.sanitize`.

- [ ] **Step 1: SettingsView — storage + status state** — next to the Codex equivalents:

```swift
    @AppStorage(AppSettings.grokSourceEnabledKey) private var grokSourceEnabled = false
```

```swift
    @State private var grokStatus = ""
    @State private var grokStatusGeneration = 0
    @State private var grokStatusTask: Task<Void, Never>?
```

- [ ] **Step 2: SettingsView — card** — after the Codex `DataSourceCard`:

```swift
                DataSourceCard(
                    icon: "atom",
                    iconColor: Color(hex: "1C1C1E"),
                    title: "Grok",
                    subtitle: "Read Grok Build weekly credit usage (unofficial API; may break).",
                    isEnabled: $grokSourceEnabled
                ) {
                    grokContent
                }
```

- [ ] **Step 3: SettingsView — lifecycle hooks** — add `loadGrokStatus()` to `.onAppear` beside `loadCodexStatus()`, and after the `codexSourceMode` `onChange`:

```swift
        .onChange(of: grokSourceEnabled) { _, enabled in
            loadGrokStatus()
            appState.setGrokSourceEnabled(enabled)
        }
```

- [ ] **Step 4: SettingsView — content + status loader** — after `loadCodexStatus()`:

```swift
    @ViewBuilder
    private var grokContent: some View {
        if grokSourceEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(
                        systemName: grokStatus.hasPrefix("Connected")
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(grokStatus.hasPrefix("Connected") ? .green : .secondary)
                    Text(grokStatus.isEmpty ? "Checking…" : grokStatus)
                }
                if let err = appState.grokError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(err)
                    }
                    .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func loadGrokStatus() {
        grokStatusTask?.cancel()
        guard grokSourceEnabled else {
            grokStatus = ""
            return
        }
        grokStatus = ""
        grokStatusGeneration += 1
        let generation = grokStatusGeneration
        grokStatusTask = Task {
            let status = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    let creds = try GrokAuthStore.load()
                    if let email = creds.email {
                        return "Connected as \(Self.maskedEmail(email))"
                    }
                    return "Connected via Grok Build CLI"
                } catch {
                    return (error as? LocalizedError)?.errorDescription
                        ?? "Grok Build CLI not signed in — run `grok login`."
                }
            }.value
            guard !Task.isCancelled, generation == grokStatusGeneration else { return }
            grokStatus = DiagnosticsSanitizer.sanitize(status)
        }
    }
```

- [ ] **Step 5: DiagnosticsView — sources section** — after the Codex block:

```swift
            if AppSettings.grokSourceEnabled {
                LabeledContent(
                    "Grok", value: appState.grokUsage != nil ? "Connected" : "Not available")
            }
```

- [ ] **Step 6: DiagnosticsView — poll section + helper** — after the Codex poll block:

```swift
            if AppSettings.grokSourceEnabled {
                LabeledContent("Grok", value: grokPollTimeText)
                if let err = appState.grokError {
                    LabeledContent("Grok error") {
                        Text(DiagnosticsSanitizer.sanitize(err))
                            .foregroundStyle(Color.cmCritical)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
```

and next to `codexPollTimeText`:

```swift
    private var grokPollTimeText: String {
        guard let date = appState.grokLastPolledAt else { return "Never" }
        return isoFormatter.string(from: date)
    }
```

- [ ] **Step 7: CHANGELOG** — add at the top, matching the existing entry format:

```markdown
## Unreleased

- feat: add Grok usage source — opt-in popover card reading Grok Build CLI
  weekly credit usage (unofficial endpoint; sign-in owned by the `grok` CLI).
```

- [ ] **Step 8: Compile check + full Core suite**

Run: `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

Run: `swift test --package-path ClaudeMeterCore`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add ClaudeMeter/SettingsView.swift ClaudeMeter/DiagnosticsView.swift CHANGELOG.md
git commit -m "feat: add Grok settings toggle and diagnostics"
```

---

### Task 7: Docs — AGENTS.md provider notes

**Files:**
- Modify: `AGENTS.md` (new section after "## Cursor usage (opt-in)" / Codex notes)

**Interfaces:** none (docs only).

- [ ] **Step 1: Add the section** (adjust placement beside the Cursor/Codex sections):

```markdown
## Grok usage (opt-in)

- **Separate from Claude pipeline** — `grokSourceEnabled` defaults `false`; polled in parallel via `pollGrok`, not part of `makePipeline()`.
- **Token read-only** — `GrokAuthStore` reads `~/.grok/auth.json` (`GROK_HOME` override), prefers the `https://auth.x.ai::<client-id>` OIDC entry over legacy `https://accounts.x.ai/sign-in`. Never refreshes, never writes; expired token (~6 h TTL, CLI-owned refresh) → `loginRequired`, never sent.
- **API** — unofficial `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` (same upstream call as the CLI's `/usage`); may break without notice. `creditUsagePercent` is authoritative; **proto3 omits zero fields** — absent percent with a present `currentPeriod` decodes as 0, not missing. Timestamps carry microsecond fractions — `GrokTimestamp.parse` strips the fraction (`ISO8601DateFormatter.withFractionalSeconds` requires exactly 3 digits).
- **Monetary `{val}` wrappers are minor units** (cents): `onDemandUsed`/`onDemandCap`/`prepaidBalance`.
- **UX** — `grokError` surfaces in popover/settings/diagnostics. Menu bar stays Claude-only; not in widget/notifications.
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: add Grok usage source notes to AGENTS.md"
```

---

## Verification (post-plan)

1. `swift test --package-path ClaudeMeterCore` — all green.
2. `xcodebuild -scheme ClaudeMeter -configuration Debug CODE_SIGNING_ALLOWED=NO` — builds.
3. Manual: enable Grok in Settings → Data on this machine (grok 0.2.93 signed in) → popover shows Grok card with live weekly percent matching `grok` CLI `/usage`.
