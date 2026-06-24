import Foundation

public enum CursorError: Error, LocalizedError {
    case notDetected
    case unauthorized
    case invalidResponse
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .notDetected:    "Cursor not detected — sign in to the Cursor app."
        case .unauthorized:   "Cursor session expired — open Cursor to refresh it."
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

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static let baseURL = "https://api2.cursor.sh"
    private static let tokenURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static let usagePath = "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    private static let planInfoPath = "/aiserver.v1.DashboardService/GetPlanInfo"

    private let stateQueue = DispatchQueue(label: "com.jewei.claudemeter.cursor-provider.state")
    private var cachedAccessToken: String?

    public init() {}

    public func fetchUsage(now: Date = Date()) async throws -> CursorUsage {
        guard let creds = CursorTokenStore.detect() else { throw CursorError.notDetected }

        var token = cachedToken() ?? creds.accessToken
        if CursorTokenStore.isExpiringSoon(token, now: now), let refreshToken = creds.refreshToken,
           let refreshed = try? await refresh(refreshToken) {
            token = refreshed
            setCachedToken(refreshed)
        }

        do {
            return try await fetch(token: token, credentials: creds, now: now)
        } catch CursorError.unauthorized {
            guard let refreshToken = creds.refreshToken,
                  let refreshed = try? await refresh(refreshToken) else {
                setCachedToken(nil)
                throw CursorError.unauthorized
            }
            setCachedToken(refreshed)
            return try await fetch(token: refreshed, credentials: creds, now: now)
        }
    }

    // MARK: - API

    private func fetch(token: String, credentials: CursorCredentials, now: Date) async throws -> CursorUsage {
        let usageData = try await connectPost(path: Self.usagePath, token: token)
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: usageData)

        var planName: String?
        if let planData = try? await connectPost(path: Self.planInfoPath, token: token),
           let plan = try? JSONDecoder().decode(CursorPlanInfoResponse.self, from: planData) {
            planName = plan.planInfo?.planName
        }

        return response.usage(
            planName: planName ?? credentials.membership,
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

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CursorError.invalidResponse }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw CursorError.unauthorized
        default: throw CursorError.httpError(http.statusCode)
        }
    }

    private func refresh(_ refreshToken: String) async throws -> String {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ])
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CursorError.unauthorized
        }
        return try JSONDecoder().decode(CursorOAuthResponse.self, from: data).accessToken
    }

    // MARK: - In-memory token cache

    private func cachedToken() -> String? {
        stateQueue.sync { cachedAccessToken }
    }

    private func setCachedToken(_ token: String?) {
        stateQueue.sync { cachedAccessToken = token }
    }
}
