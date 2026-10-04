import Foundation
import MeterPlatform

/// Reads one home through `codex app-server`, so Codex can renew or find its own sign-in.
///
/// The provider uses recovery only when the normal request cannot work: the auth file is
/// missing, unusable, or unreadable, the access token expires within a minute, or the usage
/// request returned HTTP 401 or 403. The live implementation starts one short-lived child
/// process per call. Tests inject a fake.
public protocol CodexRecovery: Sendable {
    /// Reads the account and its rate limits for `home`.
    ///
    /// - Parameters:
    ///   - home: The Codex home to read.
    ///   - environment: The app's environment with `CODEX_HOME` set to the home directory.
    /// - Returns: The raw JSON-RPC results, which the provider maps.
    /// - Throws: `CancellationError`, or an error whose description tells the user what to do.
    func recover(_ home: CodexHome, environment: [String: String]) async throws
        -> CodexRecoveryReply
}

/// The raw results of one recovery.
public struct CodexRecoveryReply: Sendable, Equatable {
    /// The `result` of `account/read`, or nil when Codex answered that step with an error.
    public var account: JSONValue?
    /// The `result` of `account/rateLimits/read`, or nil when the account uses an API key and
    /// the rate limits were not requested.
    public var rateLimits: JSONValue?

    public init(account: JSONValue?, rateLimits: JSONValue?) {
        self.account = account
        self.rateLimits = rateLimits
    }
}
