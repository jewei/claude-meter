import Foundation
import MeterDomain
import MeterPlatform

/// One login to read in automatic mode: a config dir, or Claude Code's active login when no
/// config dir matches its Keychain item.
struct LoginSlot: Sendable, Equatable {
    let id: AccountID
    let name: String
    /// Keychain services to try, preferred first.
    let services: [String]
    /// The `.claude.json` that names the login, when the slot has a config dir.
    let identityFile: URL?
    /// A folder problem. Such a slot is listed but never read.
    let issue: UsageIssue?

    init(account: ClaudeAccount, home: URL) {
        id = account.id
        name = account.name
        services = ClaudeCodeKeychain.services(for: account)
        identityFile = LocalIdentity.file(for: account.directory, home: home)
        issue = account.issue
    }

    /// The active login of a Keychain item that matches no config dir. It keeps its own key,
    /// `oauth-<first 8 hex of SHA-256 of the service>`, and never takes the default account.
    init(unmappedService service: String) {
        id = AccountID("oauth-" + ClaudeCodeKeychain.shortHash(service))
        name = id.rawValue
        services = [service]
        identityFile = nil
        issue = nil
    }

    /// The legacy item when `~/.claude` does not exist. It keeps the default account key.
    static let legacyDefault = LoginSlot(
        id: ClaudeAccount.defaultID,
        name: ConfigDirectoryScanner.name(for: ClaudeAccount.defaultID),
        services: [ClaudeCodeKeychain.legacyService])

    private init(id: AccountID, name: String, services: [String]) {
        self.id = id
        self.name = name
        self.services = services
        self.identityFile = nil
        self.issue = nil
    }
}

/// What a slot's credential and identity say about its login now.
enum LoginRead: Sendable {
    case signedIn(ClaudeCredential, owner: AccountOwner, identity: LocalIdentity?)
    case failed(AccountFailure, status: OwnerStatus)

    var status: OwnerStatus {
        switch self {
        case .signedIn(_, let owner, _): .signedIn(owner)
        case .failed(_, let status): status
        }
    }
}

/// Reads a slot's credential and identity. The owner is the identity from `.claude.json`
/// when it names an account, otherwise a digest of the access token.
struct LoginReader: Sendable {
    let keychain: ClaudeCodeKeychain
    let fileTimeout: Duration

    /// Throws only `CancellationError`.
    func read(_ slot: LoginSlot) async throws -> LoginRead {
        switch try await keychain.credential(services: slot.services) {
        case .missing:
            return .failed(.credentialsMissing, status: .signedOut)
        case .invalid:
            return .failed(.credentialsInvalid, status: .unknown)
        case .unavailable:
            return .failed(.credentialsUnavailable, status: .unknown)
        case .found(let credential):
            let identity = await identity(slot.identityFile)
            let owner = identity?.owner ?? .credential(Digest.sha256(credential.accessToken))
            return .signedIn(credential, owner: owner, identity: identity)
        }
    }

    /// The identity in `file`, or nil when it is missing or unreadable.
    func identity(_ file: URL?) async -> LocalIdentity? {
        guard let file else { return nil }
        return try? await BlockingIO.run(timeout: fileTimeout) { _ in LocalIdentity.read(file) }
    }
}
