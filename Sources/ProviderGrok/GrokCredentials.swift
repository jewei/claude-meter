import Foundation
import MeterDomain
import MeterPlatform

/// One sign-in entry of the Grok Build CLI, read without change from `auth.json`.
struct GrokCredentials: Hashable, Sendable {
    /// Where the account identity comes from, for Diagnostics.
    enum IdentitySource: String, Sendable {
        case tokenSubject = "Token subject"
        case authFile = "Sign-in file account ID"
        case email = "Sign-in file email"
        case tokenDigest = "Token digest"
    }

    /// The top-level key of the entry, such as `https://auth.x.ai::<client>`.
    let scope: String
    let bearer: String
    let expiresAt: Date?
    /// `user_id` or `account_id` of the entry, when the CLI wrote one.
    let accountID: String?
    /// The SHA-256 digest of the entry's `email`, trimmed and lowercased. Only the digest is
    /// kept, so the address never reaches a reading or the disk.
    let emailDigest: String?

    init(
        scope: String, bearer: String, expiresAt: Date?, accountID: String?,
        email: String? = nil
    ) {
        self.scope = scope
        self.bearer = bearer
        self.expiresAt = expiresAt
        self.accountID = accountID
        let normalized = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.emailDigest = normalized.flatMap {
            $0.isEmpty ? nil : Digest.sha256(parts: ["grok", "email", $0])
        }
    }

    /// A key this close to its expiry counts as expired. Sent, it would come back as HTTP 401
    /// after a clock difference or a slow request, with a harsher message.
    static let expiryMargin: TimeInterval = 30

    /// Whether `expires_at` has passed or is at most ``expiryMargin`` away. Such a key is
    /// never sent.
    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(Self.expiryMargin)
    }

    /// The `sub` claim when the bearer is a JSON Web Token.
    var subject: String? {
        JWTClaims(token: bearer)?.string("sub")
    }

    var identitySource: IdentitySource {
        if subject != nil { return .tokenSubject }
        if accountID != nil { return .authFile }
        if emailDigest != nil { return .email }
        return .tokenDigest
    }

    /// The stable account when the token or the entry names one: the token's `sub`, then the
    /// entry's account ID, then its email. Real Grok keys are opaque `oidc-…` tokens and the
    /// CLI writes no account ID, so the email is what survives a renewal in practice. Only
    /// without any of them is the owner the token itself, which changes when the CLI renews it.
    var owner: AccountOwner {
        if let identity = subject ?? accountID {
            return .identity(Digest.sha256(parts: ["grok", identity]))
        }
        if let emailDigest { return .identity(emailDigest) }
        return .credential(Digest.sha256(parts: ["grok", bearer]))
    }
}

/// The result of one read of `auth.json`.
enum GrokCredentialLookup: Sendable {
    /// The entry to use. Check ``GrokCredentials/isExpired(at:)`` before sending it.
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
