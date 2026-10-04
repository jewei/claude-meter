import Foundation

extension ManualLogin {
    /// Why the manual login cannot give a usable token now. The description keeps the reason,
    /// so logs and Settings can show it.
    enum Failure: Error, Equatable, LocalizedError {
        /// No manual login is stored.
        case missing
        case invalid
        case unavailable(String)
        /// The token expired and there is no refresh token.
        case expired
        /// The refresh token got `invalid_grant`, or the server rejected the tokens of this
        /// connection after a refresh.
        case rejected
        /// Waiting after earlier temporary refresh failures.
        case deferred
        case refreshFailed(String)
        /// Disconnected or reconnected while the work was in progress.
        case changed

        var errorDescription: String? {
            switch self {
            case .missing: "No manual Claude login is stored."
            case .invalid: "The manual Claude login cannot be read."
            case .unavailable(let reason): "The Keychain is unavailable. \(reason)"
            case .expired: "The manual Claude token expired, and there is no refresh token."
            case .rejected: "Anthropic rejected the manual Claude tokens."
            case .deferred: "The manual Claude token refresh waits after earlier failures."
            case .refreshFailed(let reason): "The manual Claude token refresh failed. \(reason)"
            case .changed: "The manual Claude login changed while the work ran."
            }
        }
    }
}
