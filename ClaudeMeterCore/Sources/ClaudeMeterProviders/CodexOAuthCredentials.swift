import ClaudeMeterCore
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
