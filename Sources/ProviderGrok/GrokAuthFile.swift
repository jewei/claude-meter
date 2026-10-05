import Foundation
import MeterDomain
import MeterPlatform

/// Reads the Grok Build CLI's `auth.json`. The CLI owns its login: the app never renews,
/// writes, or caches it, and never reads `refresh_token`.
struct GrokAuthFile: Sendable {
    static let maxBytes = 4 * 1024 * 1024
    static let readTimeout: Duration = .seconds(5)
    /// OIDC entries of auth.x.ai come first.
    static let oidcPrefix = "https://auth.x.ai"
    /// The legacy session entry comes second.
    static let legacyScope = "https://accounts.x.ai/sign-in"

    let url: URL

    /// - Parameter grokHome: The CLI's home directory, from ``GrokProvider/homeDirectory(environment:home:)``.
    init(grokHome: URL) {
        url = grokHome.appending(path: "auth.json")
    }

    /// Reads the login. Throws only `CancellationError`.
    func read(now: Date) async throws -> GrokCredentialLookup {
        let data: Data
        do {
            data = try await BlockingIO.run(timeout: Self.readTimeout) { [url] _ in
                try LocalFile.read(url, maxBytes: Self.maxBytes)
            }
        } catch {
            return try Self.lookup(after: error)
        }
        return Self.lookup(data, now: now)
    }

    /// The login after a failed read. A missing file is a sign-out; a file that cannot be read
    /// is unreadable; a timeout or a full blocking-I/O pool is temporary. Rethrows
    /// `CancellationError`.
    static func lookup(after error: any Error) throws -> GrokCredentialLookup {
        if error is CancellationError { throw CancellationError() }
        guard let readError = error as? LocalFile.ReadError else {
            return .unreadable(.credentialsBusy)
        }
        return readError == .notFound ? .missing : .unreadable(.credentialsUnreadable)
    }

    /// Chooses an entry. Keys sort inside each group, so the choice never depends on
    /// dictionary order: auth.x.ai entries, then the legacy entry, then any other entry.
    ///
    /// The first entry with a key is the login, so the owner never depends on the clock. When
    /// it has expired, a later entry that has not expired stands in only if it has the same
    /// owner. Otherwise the expired entry is returned: its owner keeps the last reading, and
    /// the card asks the user to renew it. An entry of another login, often an old legacy key,
    /// is never sent in its place.
    static func lookup(_ data: Data, now: Date) -> GrokCredentialLookup {
        guard let json = JSONValue.parse(data),
            case .object(let entries) = json
        else { return .unreadable(.credentialsUnreadable) }
        let keys = entries.keys.sorted()
        let oidc = keys.filter { $0.hasPrefix(oidcPrefix) }
        let legacy = keys.filter { $0 == legacyScope }
        let others = keys.filter { !$0.hasPrefix(oidcPrefix) && $0 != legacyScope }
        let candidates = (oidc + legacy + others).compactMap { scope in
            entries[scope].flatMap { credentials(scope: scope, entry: $0) }
        }
        guard let first = candidates.first else { return .missing }
        if first.isExpired(at: now),
            let sameAccount = candidates.dropFirst().first(where: {
                $0.owner == first.owner && !$0.isExpired(at: now)
            })
        {
            return .found(sameAccount)
        }
        return .found(first)
    }

    /// An entry with a non-blank `key`. `expires_at`, the account ID, and the email are
    /// optional.
    private static func credentials(scope: String, entry: JSONValue) -> GrokCredentials? {
        guard
            let key = entry["key"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else { return nil }
        let accountID = [entry["user_id"], entry["account_id"]]
            .compactMap { $0?.stringValue }
            .first { !$0.isEmpty }
        return GrokCredentials(
            scope: scope, bearer: key, expiresAt: DateParsing.date(entry["expires_at"]),
            accountID: accountID, email: entry["email"]?.stringValue)
    }
}
