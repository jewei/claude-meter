import Foundation
import MeterDomain
import MeterPlatform

/// Cursor's own login, read without change from its state database or the Keychain.
struct CursorCredentials: Hashable, Sendable {
    enum Source: String, Sendable {
        case database = "state database"
        case keychain = "Keychain"
    }

    let accessToken: String
    /// The plan that Cursor cached locally, such as "pro". Nil when Cursor stored none.
    let membership: String?
    /// Where the access token came from.
    let source: Source
    /// Whether the state database also holds a refresh token. Only Diagnostics use this:
    /// Cursor renews its own tokens, so the app never reads or sends the refresh token.
    let hasRefreshToken: Bool

    init(accessToken: String, membership: String?, source: Source, hasRefreshToken: Bool) {
        self.accessToken = accessToken
        self.membership = membership
        self.source = source
        self.hasRefreshToken = hasRefreshToken
    }

    private var claims: JWTClaims? { JWTClaims(token: accessToken) }

    /// The `exp` claim. Nil for an opaque token or a token without a numeric `exp`.
    var expiresAt: Date? { claims?.expiresAt }

    /// The `sub` claim, such as `auth0|user_123`.
    var subject: String? { claims?.string("sub") }

    /// A token this close to its expiry counts as expired. Sent, it would come back as HTTP
    /// 401 after a clock difference or a slow request, with a harsher message.
    static let expiryMargin: TimeInterval = 30

    /// A token whose known expiry has passed, or is less than ``expiryMargin`` away, is never
    /// sent.
    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(Self.expiryMargin)
    }

    /// The stable user ID when the token names one; otherwise the token itself, which
    /// changes when Cursor renews it.
    var owner: AccountOwner {
        if let subject {
            return .identity(Digest.sha256(parts: ["cursor", subject]))
        }
        return .credential(Digest.sha256(parts: ["cursor", accessToken]))
    }
}

/// The result of one read of Cursor's local login.
enum CursorCredentialLookup: Sendable {
    case found(CursorCredentials)
    /// No access token anywhere: the user is signed out.
    case missing
    /// The login could not be read right now. It proves nothing about who is signed in.
    case unreadable(CursorFailure)

    var ownerStatus: OwnerStatus {
        switch self {
        case .found(let credentials): .signedIn(credentials.owner)
        case .missing: .signedOut
        case .unreadable: .unknown
        }
    }
}
