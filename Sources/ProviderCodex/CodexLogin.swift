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
    /// The file is a JSON object, not in API-key mode, without usable tokens. `fileDigest` is
    /// the SHA-256 of its bytes.
    case noTokens(fileDigest: String)
    /// The file is not a JSON object. Codex can be in the middle of rewriting it.
    case invalid
    /// The system refused the read, for example because of the file's permissions. Only the
    /// user can change that.
    case unreadable
    /// The path is not a regular file, such as a folder, or the file is larger than
    /// ``maxFileBytes``. Codex never writes such a file, so only the user can change that.
    case unusable
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
        case LocalFile.ReadError.notRegularFile, LocalFile.ReadError.tooLarge: return .unusable
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
        case .apiKey, .missing, .noHome, .invalid, .unreadable, .unusable, .notReadInTime: nil
        }
    }

    /// The owner status that the file alone proves, for ``AccountUsage/belongs(to:)``.
    ///
    /// A missing file is unknown, because Codex can keep the login in the keyring. A file
    /// that is not a JSON object is unknown, because Codex can be rewriting it. A file that
    /// cannot be read proves nothing. Only API-key auth and a home folder that does not exist
    /// are signed out.
    var ownerStatus: OwnerStatus {
        switch self {
        case .chatGPT, .noTokens: owner.map(OwnerStatus.signedIn) ?? .unknown
        case .apiKey, .noHome: .signedOut
        case .missing, .invalid, .unreadable, .unusable, .notReadInTime: .unknown
        }
    }

    /// What a refresh does with a login before any request.
    enum Route: Equatable, Sendable {
        /// Send the usage request with these tokens.
        case request(CodexCredentials)
        /// Start app-server recovery. `reason` is the direct-path error, for the message.
        case recover(reason: CodexError)
        /// Send nothing and start nothing. The refresh fails with `error`, and `status`
        /// decides whether the previous observation stays.
        case stop(CodexError, status: OwnerStatus)
    }

    /// Only Codex can find a login without usable tokens, so recovery starts. API-key auth
    /// has no subscription quota, and a home folder that does not exist has no login. A file
    /// that cannot be read now names no owner, so the answer of a recovery could never be
    /// verified (``CodexAccountRefresh/verifiedOwner(before:after:source:report:)``): it would
    /// only start `codex app-server` at every refresh. These logins stop.
    var route: Route {
        switch self {
        case .chatGPT(let credentials): .request(credentials)
        case .missing: .recover(reason: .authFileMissing)
        case .noTokens: .recover(reason: .missingTokens)
        case .invalid: .recover(reason: .authFileInvalid)
        case .apiKey: .stop(.apiKeyOnly, status: .signedOut)
        case .noHome: .stop(.homeMissing, status: .signedOut)
        case .unreadable: .stop(.authFileUnreadable, status: .unknown)
        case .unusable: .stop(.authFileUnusable, status: .unknown)
        case .notReadInTime: .stop(.authFileTimedOut, status: .unknown)
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
        case .unusable: "Not a regular file, or too large"
        case .notReadInTime: "Not read in time"
        }
    }
}
