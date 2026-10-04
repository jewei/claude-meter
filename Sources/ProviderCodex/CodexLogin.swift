import Foundation
import MeterDomain
import MeterPlatform

/// What one home's `auth.json` says about its login.
///
/// A refresh reads the file once before the request, for the credentials and the owner
/// together, and once after it, for the owner only.
enum CodexLogin: Sendable, Equatable {
    static let maxFileBytes = 4 * 1024 * 1024

    /// The file has ChatGPT tokens.
    case chatGPT(CodexCredentials)
    /// The file selects API-key auth, which has no subscription quota.
    case apiKey
    /// There is no file. Codex can keep its tokens in another store, so recovery can still work.
    case missing
    /// The file exists but has no usable tokens. `fileDigest` is the SHA-256 of its bytes.
    case unusable(CodexError, fileDigest: String)
    /// The file could not be read now, for example because the read timed out.
    case unreadable

    /// Reads and parses `home`'s auth file without blocking a cooperative thread.
    /// Throws only `CancellationError`.
    static func read(_ home: CodexHome, timeout: Duration) async throws -> CodexLogin {
        let file = home.authFile
        do {
            let data = try await BlockingIO.run(timeout: timeout) { _ in
                try LocalFile.read(file, maxBytes: maxFileBytes)
            }
            return parse(data)
        } catch LocalFile.ReadError.notFound {
            return .missing
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unreadable
        }
    }

    /// The `auth_mode` rule comes first: API-key mode wins over tokens, and `chatgpt` mode
    /// wins over a stored `OPENAI_API_KEY`. Without a mode, a stored key means API-key auth.
    static func parse(_ data: Data) -> CodexLogin {
        let digest = Digest.sha256(data)
        guard let fields = JSONValue.parse(data)?.objectValue else {
            return .unusable(.authFileInvalid, fileDigest: digest)
        }
        let mode = CodexAuthMode(fields["auth_mode"]?.text)
        if mode == .apiKey { return .apiKey }
        if mode != .chatGPT, fields["OPENAI_API_KEY"]?.text != nil { return .apiKey }
        guard let tokens = fields["tokens"]?.objectValue,
            let accessToken = tokens["access_token"]?.text ?? tokens["accessToken"]?.text
        else {
            return .unusable(.missingTokens, fileDigest: digest)
        }
        return .chatGPT(
            CodexCredentials(
                accessToken: accessToken,
                idToken: tokens["id_token"]?.text ?? tokens["idToken"]?.text,
                accountID: tokens["account_id"]?.text ?? tokens["accountId"]?.text))
    }

    /// Who the login belongs to, for retention. Nil when no file names an owner.
    var owner: AccountOwner? {
        switch self {
        case .chatGPT(let credentials): credentials.owner
        case .unusable(_, let digest): .credential(digest)
        case .apiKey, .missing, .unreadable: nil
        }
    }

    var ownerStatus: OwnerStatus {
        switch self {
        case .chatGPT, .unusable: owner.map(OwnerStatus.signedIn) ?? .unknown
        case .apiKey, .missing: .signedOut
        case .unreadable: .unknown
        }
    }

    /// A short label for Diagnostics.
    var summary: String {
        switch self {
        case .chatGPT: "ChatGPT tokens"
        case .apiKey: "API key"
        case .missing: "No auth file"
        case .unusable(let error, _): error == .missingTokens ? "No tokens" : "Unreadable JSON"
        case .unreadable: "Could not read the auth file"
        }
    }
}
