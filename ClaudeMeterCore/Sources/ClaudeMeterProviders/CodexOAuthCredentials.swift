import ClaudeMeterCore
import CryptoKit
import Foundation

public struct CodexOAuthCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let accountId: String?

    public init(accessToken: String, refreshToken: String?, idToken: String?, accountId: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
    }
}

public enum CodexOAuthCredentialsError: Error, LocalizedError, Equatable {
    case notFound
    case apiKeyOnly
    case missingTokens
    case decodeFailed
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "Codex auth file not found; using Codex CLI if available."
        case .apiKeyOnly:
            "Codex is using API key auth; direct OAuth usage is unavailable."
        case .missingTokens:
            "Codex auth file has no ChatGPT OAuth tokens."
        case .decodeFailed:
            "Could not decode Codex auth file."
        case .unreadable:
            "Could not read Codex auth file."
        }
    }
}

public enum CodexOAuthCredentialsStore {
    private static let maximumAuthFileBytes = 4 * 1_024 * 1_024

    /// Reads only the configured home's bounded auth file. The returned value has
    /// no credentials or personal data and can cross the provider/app boundary.
    public static func identity(codexHome: URL) -> CodexCredentialIdentity {
        do {
            let data = try BoundedRegularFileReader.read(
                at: codexHome.appendingPathComponent("auth.json"),
                maximumByteCount: maximumAuthFileBytes)
            return identity(data: data)
        } catch  where BoundedRegularFileReader.isMissingFileError(error) {
            // Some app-server installations use a credential backend instead.
            // Current quota can still be shown, but cannot get a durable owner.
            return CodexCredentialIdentity(ownerID: nil, sourceFingerprint: "missing")
        } catch {
            return .unavailable
        }
    }

    public static func identity(data: Data) -> CodexCredentialIdentity {
        let fingerprint = digest(data)
        guard let credentials = try? parse(data: data) else {
            return CodexCredentialIdentity(ownerID: nil, sourceFingerprint: fingerprint)
        }
        let idClaims = claims(credentials.idToken)
        let accessClaims = claims(credentials.accessToken)
        let idAuth = idClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let accessAuth = accessClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let workspace =
            credentials.accountId
            ?? string(idAuth["chatgpt_account_id"]) ?? string(accessAuth["chatgpt_account_id"])
            ?? string(idClaims["chatgpt_account_id"]) ?? string(accessClaims["chatgpt_account_id"])
        let member =
            string(idAuth["chatgpt_user_id"]) ?? string(accessAuth["chatgpt_user_id"])
            ?? string(idClaims["sub"]) ?? string(accessClaims["sub"])
        guard let workspace, let member else {
            return CodexCredentialIdentity(ownerID: nil, sourceFingerprint: fingerprint)
        }
        // Length-prefix the fields so delimiters inside an identifier cannot alias
        // another account. Token rotation does not change this stable owner.
        let owner =
            "codex-owner-v1:\(member.utf8.count):\(member):\(workspace.utf8.count):\(workspace)"
        return CodexCredentialIdentity(
            ownerID: digest(Data(owner.utf8)), sourceFingerprint: fingerprint)
    }

    private static func claims(_ token: String?) -> [String: Any] {
        guard let token else { return [:] }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        // Claims are an account-change signal, never proof of authentication.
        return value
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> CodexOAuthCredentials {
        let url = authFileURL(env: env, fileManager: fileManager)
        do {
            let data = try BoundedRegularFileReader.read(
                at: url, maximumByteCount: maximumAuthFileBytes)
            return try parse(data: data)
        } catch  where BoundedRegularFileReader.isMissingFileError(error) {
            throw CodexOAuthCredentialsError.notFound
        } catch let error as CodexOAuthCredentialsError {
            throw error
        } catch {
            throw CodexOAuthCredentialsError.unreadable
        }
    }

    static func authFileURL(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !codexHome.isEmpty
        {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    public static func parse(data: Data) throws -> CodexOAuthCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthCredentialsError.decodeFailed
        }
        if let apiKey = json["OPENAI_API_KEY"] as? String,
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw CodexOAuthCredentialsError.apiKeyOnly
        }
        guard let tokens = json["tokens"] as? [String: Any],
            let accessToken = string(tokens["access_token"]) ?? string(tokens["accessToken"]),
            !accessToken.isEmpty
        else {
            throw CodexOAuthCredentialsError.missingTokens
        }
        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: string(tokens["refresh_token"]) ?? string(tokens["refreshToken"]),
            idToken: string(tokens["id_token"]) ?? string(tokens["idToken"]),
            accountId: string(tokens["account_id"]) ?? string(tokens["accountId"]))
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A stable observation owner plus an in-memory change detector for sources whose
/// account claims are unavailable. Never persist the credential fingerprint.
public struct CodexCredentialIdentity: Sendable, Equatable {
    public let ownerID: String?
    private let sourceFingerprint: String?

    public static let unavailable = CodexCredentialIdentity(ownerID: nil, sourceFingerprint: nil)

    public init(ownerID: String?, sourceFingerprint: String?) {
        self.ownerID = ownerID
        self.sourceFingerprint = sourceFingerprint
    }

    public func acceptsResult(after current: Self) -> Bool {
        if let ownerID { return current.ownerID == ownerID }
        return current.ownerID == nil && sourceFingerprint != nil
            && sourceFingerprint == current.sourceFingerprint
    }
}
