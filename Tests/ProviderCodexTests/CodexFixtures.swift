import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

/// The parent of every Codex suite. The suites run in parallel with the rest of the package.
@Suite struct CodexTests {}

/// Tokens, files, and responses for Codex tests.
enum CodexFixtures {
    static let authClaim = "https://api.openai.com/auth"

    /// An access token whose claims name a ChatGPT member and workspace.
    static func accessToken(
        user: String? = "user-1", workspace: String? = "workspace-1",
        expiresAt: Date? = .reference(.days(10)), tag: String = "a"
    ) -> String {
        var auth: [String: Any] = [:]
        auth["chatgpt_user_id"] = user
        auth["chatgpt_account_id"] = workspace
        var claims: [String: Any] = ["tag": tag]
        if !auth.isEmpty { claims[authClaim] = auth }
        if let expiresAt { claims["exp"] = expiresAt.timeIntervalSince1970 }
        return JWTFixture.token(claims)
    }

    /// `auth.json` text in ChatGPT mode.
    static func authJSON(
        accessToken: String = accessToken(), accountID: String? = "workspace-1",
        mode: String? = "chatgpt"
    ) -> String {
        var tokens: [String: Any] = ["access_token": accessToken, "refresh_token": "never-read"]
        tokens["account_id"] = accountID
        var root: [String: Any] = ["tokens": tokens]
        root["auth_mode"] = mode
        return json(root)
    }

    static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    static func value(_ text: String) -> JSONValue? {
        JSONValue.parse(Data(text.utf8))
    }

    /// A `wham/usage` body with two windows and credits.
    static let usage = """
        {"plan_type":"plus",
         "rate_limit":{
           "primary_window":{"used_percent":9,"reset_at":1791118800,"limit_window_seconds":18000},
           "secondary_window":{"used_percent":43,"reset_at":1791547200,"limit_window_seconds":604800}},
         "credits":{"has_credits":true,"unlimited":false,"balance":"7.5"}}
        """

    /// A `wham/usage` body that reports three reset credits.
    static let usageWithResets = """
        {"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000}},
         "rate_limit_reset_credits":{"available_count":3}}
        """

    /// An `account/rateLimits/read` result.
    static let rateLimits = """
        {"rateLimits":{
           "planType":"pro",
           "primary":{"usedPercent":22,"windowDurationMins":300,"resetsAt":1791118800},
           "secondary":{"usedPercent":43,"windowDurationMins":10080,"resetsAt":1791547200},
           "credits":{"hasCredits":true,"unlimited":false,"balance":"112.4"}},
         "rateLimitResetCredits":{"availableCount":4,"credits":[
           {"title":"Full reset","expiresAt":1791201600},{"title":"Full reset","expiresAt":1791288000}]}}
        """

    /// An `account/read` result in the upstream shape.
    static let chatGPTAccount =
        #"{"account":{"type":"chatgpt","email":"me@example.com","planType":"plus"},"requiresOpenaiAuth":true}"#

    /// The owner that recovery gives a login without an auth file, from `chatGPTAccount`.
    static let keyringOwner = AccountOwner.credential(
        Digest.sha256(parts: ["codex-app-server", "me@example.com"]))
}

/// A ``CodexRecovery`` that answers from a closure and records each call.
final class FakeRecovery: CodexRecovery {
    typealias Handler =
        @Sendable (CodexHome, [String: String]) async throws -> CodexRecoveryReply

    struct Unused: Error, LocalizedError {
        var errorDescription: String? { "Recovery was not expected." }
    }

    private let handler: Handler
    private let log = Locked<[[String: String]]>([])

    init(_ handler: @escaping Handler = { _, _ in throw Unused() }) {
        self.handler = handler
    }

    /// Answers every call with these JSON-RPC results.
    convenience init(account: String? = CodexFixtures.chatGPTAccount, rateLimits: String?) {
        let reply = CodexRecoveryReply(
            account: account.flatMap(CodexFixtures.value),
            rateLimits: rateLimits.flatMap(CodexFixtures.value))
        self.init { _, _ in reply }
    }

    var calls: Int { log.value.count }
    var environments: [[String: String]] { log.value }

    func recover(
        _ home: CodexHome, environment: [String: String]
    ) async throws -> CodexRecoveryReply {
        log.withLock { $0.append(environment) }
        return try await handler(home, environment)
    }
}

/// One temporary implicit home and a provider that reads it.
///
/// The provider never finds a real `codex`: its only install folder is `root/bin`, which
/// holds a fake one only when `hasCLI` is true. Recovery is always a ``FakeRecovery``.
struct CodexTestBed {
    let root: TemporaryDirectory
    let extras: [URL]
    let http: FakeHTTPClient
    let recovery: FakeRecovery
    let now: Date
    let provider: CodexProvider

    /// The implicit home is `root/home`. Extra homes are `root/<name>`.
    init(
        extraHomes: [String] = [], http: FakeHTTPClient = FakeHTTPClient(json: CodexFixtures.usage),
        recovery: FakeRecovery = FakeRecovery(), now: Date = .reference(),
        limits: CodexLimits = .standard, hasCLI: Bool = false
    ) throws {
        let root = try TemporaryDirectory()
        _ = try root.makeDirectory("home")
        let extras = try extraHomes.map { try root.makeDirectory($0) }
        if hasCLI {
            let cli = try root.write("#!/bin/sh\nexit 1\n", to: "bin/codex")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: cli.path)
        }
        self.root = root
        self.extras = extras
        self.http = http
        self.recovery = recovery
        self.now = now
        self.provider = CodexProvider(
            configuration: { CodexConfiguration(extraHomes: extras) }, http: http,
            environment: ["CODEX_HOME": root.path("home").path, "PATH": ""],
            home: root.url, recovery: recovery, now: { now }, limits: limits,
            installFolders: [root.path("bin")])
    }

    /// Another provider for the same homes, HTTP client, and recovery, with other limits or
    /// another clock.
    func provider(limits: CodexLimits = .standard, now: Date? = nil) -> CodexProvider {
        let extras = self.extras
        let now = now ?? self.now
        return CodexProvider(
            configuration: { CodexConfiguration(extraHomes: extras) }, http: http,
            environment: ["CODEX_HOME": root.path("home").path, "PATH": ""],
            home: root.url, recovery: recovery, now: { now }, limits: limits,
            installFolders: [root.path("bin")])
    }

    /// Another provider for the same homes whose clock reads `clock`, so one provider keeps
    /// what it holds in memory across fetches at different times.
    func provider(clock: Locked<Date>, limits: CodexLimits = .standard) -> CodexProvider {
        let extras = self.extras
        return CodexProvider(
            configuration: { CodexConfiguration(extraHomes: extras) }, http: http,
            environment: ["CODEX_HOME": root.path("home").path, "PATH": ""],
            home: root.url, recovery: recovery, now: { clock.value }, limits: limits,
            installFolders: [root.path("bin")])
    }

    /// Writes `auth.json` into a home folder (`home` is the implicit one).
    func writeAuth(_ text: String = CodexFixtures.authJSON(), home: String = "home") throws {
        try root.write(text, to: "\(home)/auth.json")
    }

    func homes() async -> [CodexHome] {
        await provider.homes(for: CodexConfiguration(extraHomes: extras))
    }

    func remove() {
        root.remove()
    }
}
