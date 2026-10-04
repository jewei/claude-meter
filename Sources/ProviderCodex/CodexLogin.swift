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
    /// The home folder exists without an auth file. Codex can keep its tokens in the keyring,
    /// so only Codex itself can say who is signed in.
    case missing
    /// The home folder does not exist, so Codex has no login there.
    case noHome
    /// The file is JSON without usable tokens. `fileDigest` is the SHA-256 of its bytes.
    case noTokens(fileDigest: String)
    /// The file is not JSON. Codex can be in the middle of rewriting it.
    case invalid
    /// The file cannot be read: it is not a regular file, it is too large, or the system
    /// refused the read. Only the user can change that.
    case unreadable
    /// The read did not finish in time, or no blocking-read thread was free. It can pass.
    case notReadInTime

    /// Reads and parses `home`'s auth file without blocking a cooperative thread.
    /// Throws only `CancellationError`.
    static func read(_ home: CodexHome, timeout: Duration) async throws -> CodexLogin {
        let file = home.authFile
        let directory = home.directory
        do {
            return try await BlockingIO.run(timeout: timeout) { _ in
                do {
                    return parse(try LocalFile.read(file, maxBytes: maxFileBytes))
                } catch LocalFile.ReadError.notFound {
                    return LocalFile.isDirectory(directory) ? .missing : .noHome
                }
            }
        } catch {
            return try readFailure(error)
        }
    }

    /// The login for a read that failed with `error`. Rethrows `CancellationError`.
    static func readFailure(_ error: any Error) throws -> CodexLogin {
        switch error {
        case is CancellationError: throw CancellationError()
        case is TimeoutError, is BlockingIO.BusyError: return .notReadInTime
        default: return .unreadable
        }
    }

    /// The `auth_mode` rule comes first: API-key mode wins over tokens, and `chatgpt` mode
    /// wins over a stored `OPENAI_API_KEY`. Without a mode, a stored key means API-key auth.
    static func parse(_ data: Data) -> CodexLogin {
        guard let fields = JSONValue.parse(data)?.objectValue else { return .invalid }
        let mode = CodexAuthMode(fields["auth_mode"]?.text)
        if mode == .apiKey { return .apiKey }
        if mode != .chatGPT, fields["OPENAI_API_KEY"]?.text != nil { return .apiKey }
        guard let tokens = fields["tokens"]?.objectValue,
            let accessToken = tokens["access_token"]?.text ?? tokens["accessToken"]?.text
        else {
            return .noTokens(fileDigest: Digest.sha256(data))
        }
        return .chatGPT(
            CodexCredentials(
                accessToken: accessToken,
                idToken: tokens["id_token"]?.text ?? tokens["idToken"]?.text,
                accountID: tokens["account_id"]?.text ?? tokens["accountId"]?.text))
    }

    /// Who the login belongs to, for retention. Nil when the file names no owner.
    var owner: AccountOwner? {
        switch self {
        case .chatGPT(let credentials): credentials.owner
        case .noTokens(let digest): .credential(digest)
        case .apiKey, .missing, .noHome, .invalid, .unreadable, .notReadInTime: nil
        }
    }

    /// The owner status that the file alone proves, for ``AccountUsage/belongs(to:)``.
    ///
    /// A missing file is unknown, because Codex can keep the login in the keyring. A file
    /// that is not JSON is unknown, because Codex can be rewriting it. A file that cannot be
    /// read proves nothing. Only API-key auth and a home folder that does not exist are signed
    /// out.
    var ownerStatus: OwnerStatus {
        switch self {
        case .chatGPT, .noTokens: owner.map(OwnerStatus.signedIn) ?? .unknown
        case .apiKey, .noHome: .signedOut
        case .missing, .invalid, .unreadable, .notReadInTime: .unknown
        }
    }

    /// The direct-path error that sends this login to recovery. Nil for ChatGPT tokens, which
    /// send the usage request first, and for logins that recovery cannot help.
    var recoveryReason: CodexError? {
        switch self {
        case .missing: .authFileMissing
        case .noTokens: .missingTokens
        case .invalid: .authFileInvalid
        case .unreadable: .authFileUnreadable
        case .notReadInTime: .authFileTimedOut
        case .chatGPT, .apiKey, .noHome: nil
        }
    }

    /// A short label for Diagnostics.
    var summary: String {
        switch self {
        case .chatGPT: "ChatGPT tokens"
        case .apiKey: "API key"
        case .missing: "No auth file"
        case .noHome: "No home folder"
        case .noTokens: "No tokens"
        case .invalid: "Unreadable JSON"
        case .unreadable: "Could not read the auth file"
        case .notReadInTime: "Not read in time"
        }
    }
}
