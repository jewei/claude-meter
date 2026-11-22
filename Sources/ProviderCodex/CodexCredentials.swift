import Foundation
import MeterDomain
import MeterPlatform

/// The ChatGPT tokens in one home's `auth.json`. Codex owns the file; the app only reads it
/// and never uses the refresh token.
struct CodexCredentials: Sendable, Equatable {
    /// The access token goes to recovery this long before its `exp` claim.
    static let renewalMargin: TimeInterval = 60

    private static let authClaim = "https://api.openai.com/auth"

    let accessToken: String
    let idToken: String?
    /// The ChatGPT workspace, sent as `ChatGPT-Account-Id`.
    let accountID: String?
    /// Cached `exp` claim of `accessToken` so repeated checks never re-decode the JWT.
    private let accessExpiresAt: Date?
    /// The ChatGPT member and workspace when the tokens name both. Otherwise the access token
    /// itself, which changes when Codex renews it.
    let owner: AccountOwner

    init(accessToken: String, idToken: String?, accountID: String?) {
        self.accessToken = accessToken
        self.idToken = idToken
        self.accountID = accountID
        let accessClaims = JWTClaims(token: accessToken)
        self.accessExpiresAt = accessClaims?.expiresAt
        let claims = [idToken.flatMap(JWTClaims.init(token:)), accessClaims].compactMap { $0 }
        let workspace =
            accountID
            ?? Self.first(in: claims, [Self.authClaim, "chatgpt_account_id"])
            ?? Self.first(in: claims, ["chatgpt_account_id"])
        let member =
            Self.first(in: claims, [Self.authClaim, "chatgpt_user_id"])
            ?? Self.first(in: claims, ["sub"])
        if let member, let workspace {
            self.owner = .identity(Digest.sha256(parts: ["codex", member, workspace]))
        } else {
            self.owner = .credential(Digest.sha256(accessToken))
        }
    }

    /// Whether the access token expires within one minute. An unknown or malformed `exp`
    /// claim is not expired: the request decides.
    func needsRenewal(at now: Date) -> Bool {
        guard let expiry = accessExpiresAt else { return false }
        return expiry <= now.addingTimeInterval(Self.renewalMargin)
    }

    /// The first non-empty claim at `path`, from the ID token before the access token.
    private static func first(in claims: [JWTClaims], _ path: [String]) -> String? {
        for token in claims {
            if let value = token.string(path)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            {
                return value
            }
        }
        return nil
    }
}
