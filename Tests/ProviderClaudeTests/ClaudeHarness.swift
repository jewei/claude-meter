import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport

@testable import ProviderClaude

/// A fake home, Keychain, store, and clock for one or more providers.
final class ClaudeHarness: Sendable {
    static let user = "alice"

    let home: TemporaryDirectory
    let keychain = FakeKeychain()
    let store = MemoryStore()
    private let clock = Locked(Date.reference())
    private let settings: Locked<ClaudeConfiguration>

    init(_ connection: ClaudeConfiguration.Connection = .automatic) throws {
        home = try TemporaryDirectory()
        settings = Locked(ClaudeConfiguration(connection: connection))
    }

    deinit { home.remove() }

    var now: Date { clock.value }

    var configuration: ClaudeConfiguration {
        get { settings.value }
        set { settings.withLock { $0 = newValue } }
    }

    func advance(_ seconds: TimeInterval) {
        clock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    func provider(
        _ http: any HTTPClient, keychain: (any Keychain)? = nil,
        limits: ClaudeLimits = ClaudeLimits(),
        scan: @escaping AutomaticRefresh.Scan = ConfigDirectoryScanner.discover(
            home:configuration:)
    ) -> ClaudeProvider {
        let clock = clock
        let settings = settings
        return ClaudeProvider(
            configuration: { settings.value }, keychain: keychain ?? self.keychain, http: http,
            store: store, home: home.url, now: { clock.value }, keychainUser: Self.user,
            limits: limits, scan: scan)
    }

    /// Creates a config dir with `settings.json` and, when `account` is set, an identity file.
    @discardableResult
    func directory(
        _ name: String, account: String? = nil, organization: String = "org-1"
    ) throws -> URL {
        let directory = try home.makeDirectory(name)
        try home.write("{}", to: "\(name)/settings.json")
        if let account { try identify(directory, account: account, organization: organization) }
        return directory
    }

    /// Writes the identity file of a config dir.
    func identify(_ directory: URL, account: String, organization: String = "org-1") throws {
        let file = LocalIdentity.file(for: directory, home: home.url)
        try Data(ClaudeFixtures.identity(account: account, organization: organization).utf8)
            .write(to: file)
    }

    /// Stores Claude Code's Keychain item for a config dir: the legacy item for `~/.claude`
    /// when `legacy` is true, otherwise the hashed item.
    func signIn(
        _ directory: URL, token: String, legacy: Bool = false, expiresAt: Date? = nil,
        modifiedAt: Date = .reference()
    ) {
        let service =
            legacy
            ? ClaudeCodeKeychain.legacyService : ClaudeCodeKeychain.hashedService(for: directory)
        signIn(service: service, token: token, expiresAt: expiresAt, modifiedAt: modifiedAt)
    }

    func signIn(
        service: String, token: String, expiresAt: Date? = nil, modifiedAt: Date = .reference()
    ) {
        keychain.store(
            ClaudeFixtures.claudeCodeItem(
                accessToken: token, expiresAt: expiresAt ?? now.addingTimeInterval(3600)),
            service: service, account: Self.user, modifiedAt: modifiedAt)
    }

    func signOut(_ directory: URL, legacy: Bool = false) throws {
        let service =
            legacy
            ? ClaudeCodeKeychain.legacyService : ClaudeCodeKeychain.hashedService(for: directory)
        try keychain.deletePassword(service: service, account: Self.user)
    }

    /// The stored manual login.
    func manualItem() -> ManualCredential? {
        keychain.storedPassword(
            service: ManualCredentialVault.service, account: ManualCredentialVault.account
        )
        .flatMap { try? JSONDecoder.meter.decode(ManualCredential.self, from: Data($0.utf8)) }
    }
}

/// A Keychain that runs a hook before each write of the manual item, to hold or fail it. Other
/// calls go straight to `base`. Hooks run on the writing thread, so they may block it.
final class ScriptedKeychain: Keychain {
    typealias Hook = @Sendable (_ password: Data?) throws(KeychainError) -> Void

    let base: FakeKeychain
    private let beforeWrite: Hook
    private let log = Locked<[String]>([])

    init(base: FakeKeychain, beforeWrite: @escaping Hook) {
        self.base = base
        self.beforeWrite = beforeWrite
    }

    /// The writes that reached `base`, in order: the saved access token, or `delete`.
    var writes: [String] { log.value }

    func password(service: String, account: String?) throws(KeychainError) -> Data? {
        try base.password(service: service, account: account)
    }

    func items(servicePrefix: String, account: String?) throws(KeychainError) -> [KeychainItem] {
        try base.items(servicePrefix: servicePrefix, account: account)
    }

    func setPassword(_ password: Data, service: String, account: String) throws(KeychainError) {
        guard service == ManualCredentialVault.service else {
            return try base.setPassword(password, service: service, account: account)
        }
        try beforeWrite(password)
        try base.setPassword(password, service: service, account: account)
        let token = (try? JSONDecoder.meter.decode(ManualCredential.self, from: password))?
            .accessToken
        log.withLock { $0.append(token ?? "?") }
    }

    func deletePassword(service: String, account: String) throws(KeychainError) {
        guard service == ManualCredentialVault.service else {
            return try base.deletePassword(service: service, account: account)
        }
        try beforeWrite(nil)
        try base.deletePassword(service: service, account: account)
        log.withLock { $0.append("delete") }
    }
}

/// A one-shot signal between a blocking Keychain hook and an async test.
final class Signal: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let raised = Locked(false)

    var isRaised: Bool { raised.value }

    /// Called from the hook's thread.
    func raise() {
        raised.withLock { $0 = true }
        semaphore.signal()
    }

    /// Blocks the calling thread until ``raise()``. For hooks only.
    func block() {
        semaphore.wait()
        semaphore.signal()
    }

    /// Waits without blocking a cooperative thread. Returns false after `limit`.
    @discardableResult
    func wait(limit: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !isRaised {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

extension ClaudeHarness {
    /// `~/.claude` signed in with the legacy item and `~/.claude-work` with its hashed item.
    static func twoAccounts() throws -> ClaudeHarness {
        let harness = try ClaudeHarness()
        let main = try harness.directory(".claude", account: "acc-1")
        let work = try harness.directory(".claude-work", account: "acc-2")
        harness.signIn(main, token: "main", legacy: true)
        harness.signIn(work, token: "work")
        return harness
    }

    /// A manual harness with a stored login, `old-access` of `connection-1`.
    static func manual(expiresAt: Date?, refreshToken: String? = "old-refresh") throws
        -> ClaudeHarness
    {
        let harness = try ClaudeHarness(.manual)
        try harness.storeManual(refreshToken: refreshToken, expiresAt: expiresAt)
        return harness
    }

    /// Stores a manual login, as a Connect would.
    func storeManual(
        accessToken: String = "old-access", refreshToken: String? = "old-refresh",
        expiresAt: Date?, connectionID: String = "connection-1"
    ) throws {
        let stored = ManualCredential(
            accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt,
            connectionID: connectionID)
        keychain.store(
            String(decoding: try JSONEncoder.meter.encode(stored), as: UTF8.self),
            service: ManualCredentialVault.service, account: ManualCredentialVault.account)
    }
}

/// Answers usage requests by bearer token and token requests with `tokenResponse`.
func usageServer(
    _ bodies: [String: String], tokenResponse: HTTPResponse = .json(500, "{}")
) -> FakeHTTPClient {
    FakeHTTPClient { request in
        if request.url == TokenRefresher.url { return tokenResponse }
        guard let token = bearer(request), let body = bodies[token] else { return .json(401, "{}") }
        return .json(200, body)
    }
}

/// Lets a test hold a fake request until it chooses to release it.
actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

extension FakeHTTPClient {
    func requests(to url: URL) -> [HTTPRequest] {
        requests.filter { $0.url == url }
    }

    var usageTokens: [String] {
        requests(to: UsageAPI.url).compactMap(bearer)
    }
}
