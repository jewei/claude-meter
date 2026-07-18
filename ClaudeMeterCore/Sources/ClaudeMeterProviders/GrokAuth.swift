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
