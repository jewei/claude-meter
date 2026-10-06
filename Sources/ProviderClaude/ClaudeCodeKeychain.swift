import Foundation
import MeterDomain
import MeterPlatform

/// The outcome of reading one login's credential.
enum CredentialRead: Sendable, Equatable {
    case found(ClaudeCredential)
    /// No item: the login is signed out.
    case missing
    /// The item exists but cannot be used: unparsable, or access was refused.
    case invalid
    /// The Keychain could not answer now, for example while it is locked. Proves nothing.
    case unavailable(String)
}

/// Read-only access to Claude Code's Keychain items. Never writes, refreshes, or deletes them.
///
/// Claude Code stores one generic-password item per config dir, with the macOS user name as
/// the account. Before version 2.1.52 it used one unsuffixed service; later versions append
/// the first 8 hex characters of the SHA-256 of the config dir's canonical path.
struct ClaudeCodeKeychain: Sendable {
    static let legacyService = "Claude Code-credentials"
    static let hashedServicePrefix = "Claude Code-credentials-"
    /// Claude Code uses the macOS user name (`whoami`) as the item account.
    static let currentUser = NSUserName()

    let keychain: any Keychain
    let user: String
    let timeout: Duration

    /// The first 8 lowercase hex characters of the SHA-256 of `text` as UTF-8.
    static func shortHash(_ text: String) -> String {
        String(Digest.sha256(text).prefix(8))
    }

    static func hashedService(for directory: URL) -> String {
        hashedServicePrefix + shortHash(ConfigDirectoryScanner.canonicalPath(directory))
    }

    /// The hashed services of a config dir: the resolved path first, then the path as found
    /// or configured. They differ only for a dir reached through a symbolic link, and Claude
    /// Code may hash `CLAUDE_CONFIG_DIR` without resolving links.
    static func hashedServices(for directory: URL) -> [String] {
        let resolved = hashedService(for: directory)
        let asGiven = hashedServicePrefix + shortHash(directory.standardizedFileURL.path)
        return resolved == asGiven ? [resolved] : [resolved, asGiven]
    }

    /// Services to try for a config dir, preferred first. The default dir prefers the legacy
    /// item, because older Claude Code versions still write it.
    static func services(for account: ClaudeAccount) -> [String] {
        let hashed = hashedServices(for: account.directory)
        return account.isDefault ? [legacyService] + hashed : hashed
    }

    /// The service of the login that Claude Code uses now: the legacy item when it exists,
    /// else the most recently modified hashed item. Equal dates pick the smallest service name.
    /// Reads attributes only, never a secret. Nil when Claude Code has no login.
    func activeService() async throws -> String? {
        try await run { keychain, user in
            guard !user.isEmpty else { return nil }
            let items = try keychain.items(servicePrefix: Self.legacyService, account: user)
            if items.contains(where: { $0.service == Self.legacyService }) {
                return Self.legacyService
            }
            return items.filter { $0.service.hasPrefix(Self.hashedServicePrefix) }
                .max { lhs, rhs in
                    let lhsDate = lhs.modifiedAt ?? .distantPast
                    let rhsDate = rhs.modifiedAt ?? .distantPast
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                    return lhs.service > rhs.service
                }?.service
        }
    }

    /// Reads the first of `services` that exists. A Keychain error stops the search, so a
    /// locked Keychain never falls through to another login's item.
    func credential(services: [String]) async throws -> CredentialRead {
        do {
            return try await run { keychain, user in
                guard !user.isEmpty else { return .missing }
                for service in services {
                    // Claude Code writes its items with /usr/bin/security; a read through the
                    // same tool shows no Keychain dialog.
                    guard
                        let data = try keychain.passwordThroughSecurityTool(
                            service: service, account: user)
                    else { continue }
                    return ClaudeCredential.claudeCode(data).map(CredentialRead.found) ?? .invalid
                }
                return .missing
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch KeychainError.denied {
            return .invalid
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func run<Value: Sendable>(
        _ work: @escaping @Sendable (any Keychain, String) throws -> Value
    ) async throws -> Value {
        let keychain = keychain
        let user = user
        return try await BlockingIO.run(timeout: timeout) { _ in try work(keychain, user) }
    }
}
