import ClaudeMeterCore
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
    private static let maximumAuthFileBytes = 4 * 1_024 * 1_024

    public static func defaultAuthPath() -> URL {
        let env = ProcessInfo.processInfo.environment["GROK_HOME"]
        let root =
            env.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        return root.appendingPathComponent("auth.json")
    }

    public static func load(
        authPath: URL = defaultAuthPath(),
        now: Date = Date()
    ) throws -> GrokCredentials {
        let data: Data
        do {
            data = try BoundedRegularFileReader.read(
                at: authPath, maximumByteCount: maximumAuthFileBytes)
        } catch  where BoundedRegularFileReader.isMissingFileError(error) {
            throw GrokAuthError.missing
        } catch {
            throw GrokAuthError.unreadable
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw GrokAuthError.unreadable }

        guard let entry = preferredEntry(in: object), let key = usableKey(in: entry)
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
    ///
    /// Candidates are selected in sorted key order, never Dictionary order: with
    /// two `https://auth.x.ai::<client-id>` entries (or several unrecognized
    /// scopes in the fallback) an unordered pick would silently choose a different
    /// bearer — possibly a different account — on each launch.
    static func preferredEntry(in object: [String: Any]) -> [String: Any]? {
        let entries = object.compactMapValues { $0 as? [String: Any] }
        let keys = entries.keys.sorted()
        let oidcKeys = keys.filter { $0.hasPrefix("https://auth.x.ai") }
        let legacyKeys = keys.filter { $0 == "https://accounts.x.ai/sign-in" }
        let fallbackKeys = keys.filter { !oidcKeys.contains($0) && !legacyKeys.contains($0) }
        return (oidcKeys + legacyKeys + fallbackKeys)
            .compactMap { entries[$0] }
            .first { usableKey(in: $0) != nil }
    }

    private static func usableKey(in entry: [String: Any]) -> String? {
        guard let raw = entry["key"] as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
