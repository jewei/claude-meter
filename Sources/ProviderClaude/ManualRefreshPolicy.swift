import Foundation

/// Which manual token refreshes and usage requests may go out after earlier failures.
///
/// A refresh token rejected with `invalid_grant` is not sent again, and a connection whose
/// tokens the server rejected after a refresh gets no more requests. Temporary refresh
/// failures back off for 5 minutes, doubling up to 6 hours. ``ManualLogin`` starts a new
/// policy at each Connect and Disconnect, and the app starts one at launch.
struct ManualRefreshPolicy: Sendable {
    static let backoffBase: TimeInterval = 5 * 60
    static let backoffLimit: TimeInterval = 6 * 60 * 60

    private var rejectedRefreshToken: String?
    /// The connection whose tokens the server rejected after the refresh token was tried.
    private var rejectedConnectionID: String?
    private var transientFailures = 0
    private var backoffUntil: Date?

    /// Whether the server rejected the tokens of the connection `connectionID`.
    func isRejected(connectionID: String) -> Bool {
        rejectedConnectionID == connectionID
    }

    /// Throws ``ManualLogin/Failure/rejected`` for a dead refresh token, and
    /// ``ManualLogin/Failure/deferred`` while the backoff runs.
    func checkRefresh(_ refreshToken: String, now: Date) throws {
        if rejectedRefreshToken == refreshToken { throw ManualLogin.Failure.rejected }
        if let backoffUntil, now < backoffUntil { throw ManualLogin.Failure.deferred }
    }

    /// Stops all requests for `connectionID`. Returns false when it was stopped already.
    mutating func rejectConnection(_ connectionID: String) -> Bool {
        guard rejectedConnectionID != connectionID else { return false }
        rejectedConnectionID = connectionID
        return true
    }

    mutating func rejectRefreshToken(_ refreshToken: String) {
        rejectedRefreshToken = refreshToken
    }

    /// A refresh worked, so the backoff ends.
    mutating func recordSuccess() {
        transientFailures = 0
        backoffUntil = nil
    }

    /// A temporary failure: the next refresh waits 5 minutes, doubling up to 6 hours.
    mutating func recordTemporaryFailure(now: Date) {
        transientFailures += 1
        let delay = Self.backoffBase * pow(2, Double(min(transientFailures - 1, 16)))
        backoffUntil = now.addingTimeInterval(min(delay, Self.backoffLimit))
    }
}
