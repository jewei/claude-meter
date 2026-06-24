import Foundation

public enum CursorError: Error, LocalizedError, Equatable {
    case notDetected
    case unauthorized
    case forbidden
    case usageDisabled
    case invalidResponse
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .notDetected: "Cursor not detected — sign in to the Cursor app."
        case .unauthorized: "Cursor session expired — open Cursor to refresh it."
        case .forbidden: "Cursor denied the request — check your account permissions."
        case .usageDisabled: "Cursor usage tracking is disabled for this account."
        case .invalidResponse: "Cursor returned an unexpected response."
        case .httpError(let code): "Cursor request failed (HTTP \(code))."
        }
    }
}

/// Fetches Cursor billing-period usage from its internal dashboard API.
///
/// Reads the locally stored token (`CursorTokenStore`), calls the Connect-RPC
/// `GetCurrentPeriodUsage` endpoint, and transparently refreshes the access token
/// on expiry or a 401. Refreshed tokens are cached in memory for the app session;
/// we never write back to Cursor's own store.
public final class CursorUsageProvider: @unchecked Sendable {

    private static let baseURL = "https://api2.cursor.sh"
    private static let tokenURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static let usagePath = "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    private static let planInfoPath = "/aiserver.v1.DashboardService/GetPlanInfo"

    private let transport: any HTTPTransport
    private let stateQueue = DispatchQueue(label: "com.jewei.claudemeter.cursor-provider.state")
    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?

    public init(transport: any HTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    public func fetchUsage(now: Date = Date()) async throws -> CursorUsage {
        guard let creds = CursorTokenStore.detect() else { throw CursorError.notDetected }

        let refreshToken = readCachedRefreshToken() ?? creds.refreshToken
        var token = readCachedAccessToken() ?? creds.accessToken

        if CursorTokenStore.isExpiringSoon(token, now: now), let refreshToken,
            let refreshed = try? await refresh(refreshToken)
        {
            token = refreshed.accessToken
            setCachedTokens(access: refreshed.accessToken, refresh: refreshed.refreshToken)
        }

        do {
            return try await fetch(token: token, credentials: creds, now: now)
        } catch CursorError.unauthorized {
            if token != creds.accessToken {
                setCachedTokens(access: nil, refresh: nil)
                do {
                    return try await fetch(token: creds.accessToken, credentials: creds, now: now)
                } catch CursorError.unauthorized {}
            }
            guard let refreshToken = readCachedRefreshToken() ?? creds.refreshToken,
                let refreshed = try? await refresh(refreshToken)
            else {
                setCachedTokens(access: nil, refresh: nil)
                throw CursorError.unauthorized
            }
            setCachedTokens(access: refreshed.accessToken, refresh: refreshed.refreshToken)
            return try await fetch(token: refreshed.accessToken, credentials: creds, now: now)
        }
    }

    // MARK: - API

    private func fetch(token: String, credentials: CursorCredentials, now: Date) async throws
        -> CursorUsage
    {
        let usageData = try await connectPost(path: Self.usagePath, token: token)
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: usageData)

        var planName = credentials.membership
        if planName == nil,
            let planData = try? await connectPost(path: Self.planInfoPath, token: token),
            let plan = try? JSONDecoder().decode(CursorPlanInfoResponse.self, from: planData)
        {
            planName = plan.planInfo?.planName
        }

        return try response.validatedUsage(
            planName: planName,
            email: credentials.email,
            now: now
        )
    }

    private func connectPost(path: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        let (data, http) = try await transport.send(request)
        switch http.statusCode {
        case 200: return data
        case 401: throw CursorError.unauthorized
        case 403: throw CursorError.forbidden
        default: throw CursorError.httpError(http.statusCode)
        }
    }

    private struct RefreshResult: Sendable {
        let accessToken: String
        let refreshToken: String?
    }

    private func refresh(_ refreshToken: String) async throws -> RefreshResult {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ])
        let (data, http) = try await transport.send(request)
        guard http.statusCode == 200 else {
            throw CursorError.unauthorized
        }
        let decoded = try JSONDecoder().decode(CursorOAuthResponse.self, from: data)
        return RefreshResult(accessToken: decoded.accessToken, refreshToken: decoded.refreshToken)
    }

    // MARK: - In-memory token cache

    private func readCachedAccessToken() -> String? {
        stateQueue.sync { cachedAccessToken }
    }

    private func readCachedRefreshToken() -> String? {
        stateQueue.sync { cachedRefreshToken }
    }

    private func setCachedTokens(access: String?, refresh: String?) {
        stateQueue.sync {
            cachedAccessToken = access
            if let refresh {
                cachedRefreshToken = refresh
            } else if access == nil {
                cachedRefreshToken = nil
            }
        }
    }
}
