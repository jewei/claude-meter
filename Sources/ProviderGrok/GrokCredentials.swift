import Foundation
import MeterDomain
import MeterPlatform

/// One sign-in entry of the Grok Build CLI, read without change from `auth.json`.
struct GrokCredentials: Hashable, Sendable {
    /// Where the account identity comes from, for Diagnostics.
    enum IdentitySource: String, Sendable {
        case tokenSubject = "Token subject"
        case authFile = "Sign-in file account ID"
        case tokenDigest = "Token digest"
    }

    /// The top-level key of the entry, such as `https://auth.x.ai::<client>`.
    let scope: String
    let bearer: String
    let expiresAt: Date?
    /// `user_id` or `account_id` of the entry, when the CLI wrote one.
    let accountID: String?

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// The `sub` claim when the bearer is a JSON Web Token.
    var subject: String? {
        JWTClaims(token: bearer)?.string("sub")
    }

    var identitySource: IdentitySource {
        if subject != nil { return .tokenSubject }
        if accountID != nil { return .authFile }
        return .tokenDigest
    }

    /// The stable user ID when the token or the entry names one; otherwise the token itself,
    /// which changes when the CLI renews it.
    var owner: AccountOwner {
        if let identity = subject ?? accountID {
            return .identity(Digest.sha256(parts: ["grok", identity]))
        }
        return .credential(Digest.sha256(parts: ["grok", bearer]))
    }
}

/// The result of one read of `auth.json`.
enum GrokCredentialLookup: Sendable {
    /// The first usable entry that has not expired, or, when all have expired, the first
    /// usable entry. Check ``GrokCredentials/isExpired(at:)`` before sending it.
    case found(GrokCredentials)
    /// No file, or no entry with a key: the user is signed out.
    case missing
    /// The file could not be read right now. It proves nothing about who is signed in.
    case unreadable(GrokFailure)

    var ownerStatus: OwnerStatus {
        switch self {
        case .found(let credentials): .signedIn(credentials.owner)
        case .missing: .signedOut
        case .unreadable: .unknown
        }
    }
}
