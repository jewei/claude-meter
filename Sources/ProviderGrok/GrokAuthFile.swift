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
        } catch is CancellationError {
            throw CancellationError()
        } catch LocalFile.ReadError.notFound {
            return .missing
        } catch is LocalFile.ReadError {
            return .unreadable(.credentialsUnreadable)
        } catch {
            // A timeout or a full blocking-I/O pool is temporary.
            return .unreadable(.credentialsBusy)
        }
        return Self.lookup(data, now: now)
    }

    /// Chooses an entry. Keys sort inside each group, so the choice never depends on
    /// dictionary order: auth.x.ai entries, then the legacy entry, then any other entry.
    /// The first entry with a key that has not expired wins. When every such entry has
    /// expired, the first one is returned, so that its owner can keep the last reading.
    static func lookup(_ data: Data, now: Date) -> GrokCredentialLookup {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let entries) = json
        else { return .unreadable(.credentialsUnreadable) }
        let keys = entries.keys.sorted()
        let oidc = keys.filter { $0.hasPrefix(oidcPrefix) }
        let legacy = keys.filter { $0 == legacyScope }
        let others = keys.filter { !$0.hasPrefix(oidcPrefix) && $0 != legacyScope }
        let candidates = (oidc + legacy + others).compactMap { scope in
            entries[scope].flatMap { credentials(scope: scope, entry: $0) }
        }
        if let usable = candidates.first(where: { !$0.isExpired(at: now) }) {
            return .found(usable)
        }
        return candidates.first.map { .found($0) } ?? .missing
    }

    /// An entry with a non-blank `key`. `expires_at` and the account ID are optional.
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
            accountID: accountID)
    }
}
