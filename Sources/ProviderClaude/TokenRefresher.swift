import Foundation
import MeterDomain
import MeterPlatform

/// Exchanges a manual refresh token for new tokens at Anthropic's OAuth token endpoint.
/// Only manual logins are refreshed; Claude Code's own credentials never are.
struct TokenRefresher: Sendable {
    enum Failure: Error, Equatable {
        /// `invalid_grant`: the refresh token is dead. Only new tokens recover.
        case rejected
        /// A temporary failure, such as a network error or HTTP 5xx.
        case failed(String)
    }

    // Compile-time literal.
    static let url = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// Claude Code's public OAuth client.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let minimumLifetime: TimeInterval = 5 * 60
    static let maximumLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let requestDeadline: Duration = .seconds(15)

    let http: any HTTPClient
    let now: @Sendable () -> Date

    /// New tokens for `credential`, from `refreshToken`. A response without `refresh_token`
    /// keeps the old one. Throws ``Failure``.
    func refresh(_ credential: ManualCredential, using refreshToken: String) async throws
        -> ManualCredential
    {
        let body = try JSONEncoder.sorted.encode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
        let request = HTTPRequest(
            .post, url: Self.url, headers: ["Content-Type": "application/json"], body: body,
            retry: .never, deadline: Self.requestDeadline)
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        guard response.status == 200 else {
            throw Self.isInvalidGrant(status: response.status, body: response.body)
                ? Failure.rejected
                : Failure.failed("The token server returned HTTP \(response.status).")
        }
        guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: response.body),
            !tokens.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            tokens.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        else { throw Failure.failed("The token server sent an invalid response.") }
        let lifetime = min(
            max(TimeInterval(tokens.expiresIn), Self.minimumLifetime), Self.maximumLifetime)
        var refreshed = credential
        refreshed.accessToken = tokens.accessToken
        refreshed.refreshToken = tokens.refreshToken ?? refreshToken
        refreshed.expiresAt = DateBounds.validated(now().addingTimeInterval(lifetime))
        return refreshed
    }

    /// HTTP 400, 401, or 403 with `invalid_grant` in the JSON `error` or `error_description`.
    static func isInvalidGrant(status: Int, body: Data) -> Bool {
        guard [400, 401, 403].contains(status),
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        return ["error", "error_description"].contains { key in
            (object[key] as? String)?.localizedCaseInsensitiveContains("invalid_grant") == true
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }
}

extension JSONEncoder {
    /// Sorted keys, so a request body is the same on every run.
    fileprivate static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
