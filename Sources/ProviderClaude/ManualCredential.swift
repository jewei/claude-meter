import Foundation
import MeterDomain
import MeterPlatform

/// The manual login, as stored in the app-owned Keychain item.
///
/// JSON: `{accessToken, refreshToken, expiresAt, subscriptionType, connectionID}`. Dates are
/// ISO-8601. `expiresAt` is the real expiry; nil means unknown.
struct ManualCredential: Sendable, Equatable, Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var subscriptionType: String?
    /// A random ID made at connect time. It survives token rotation, so it names the owner of
    /// readings from this connection, and a new connection always has a new owner.
    var connectionID: String

    init(
        accessToken: String, refreshToken: String?, expiresAt: Date?, subscriptionType: String?,
        connectionID: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = DateBounds.validated(expiresAt)
        self.subscriptionType = subscriptionType
        self.connectionID = connectionID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            accessToken: try container.decode(String.self, forKey: .accessToken),
            refreshToken: try container.decodeIfPresent(String.self, forKey: .refreshToken),
            expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt),
            subscriptionType: try container.decodeIfPresent(String.self, forKey: .subscriptionType),
            connectionID: try container.decode(String.self, forKey: .connectionID))
    }

    var isUsable: Bool {
        !accessToken.isEmpty && !connectionID.isEmpty && refreshToken?.isEmpty != true
    }

    var owner: AccountOwner {
        .identity(Digest.sha256(parts: ["claude", "manual", connectionID]))
    }

    func isExpired(at now: Date) -> Bool {
        ClaudeCredential(accessToken: accessToken, expiresAt: expiresAt).isExpired(at: now)
    }
}
