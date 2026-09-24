import ClaudeMeterCore
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
/// Uses Cursor's locally stored access token without consuming its refresh token.
/// Cursor owns renewal. Expired or rejected credentials require opening Cursor.
public final class CursorUsageProvider: Sendable {
    private static let baseURL = "https://api2.cursor.sh"
    private static let usagePath = "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    private static let planInfoPath = "/aiserver.v1.DashboardService/GetPlanInfo"

    private let transport: any HTTPTransport
    private let credentialsLoader: @Sendable () throws -> CursorCredentials?

    public init(
        transport: any HTTPTransport = ProviderHTTPClient.shared,
        credentialsLoader: @escaping @Sendable () throws -> CursorCredentials? = {
            try CursorTokenStore.detect()
        }
    ) {
        self.transport = transport
        self.credentialsLoader = credentialsLoader
    }

    public func fetchUsage(now: Date = Date()) async throws -> CursorUsage {
        guard let credentials = try credentialsLoader() else { throw CursorError.notDetected }
        if let expiry = CursorTokenStore.expiry(of: credentials.accessToken), expiry <= now {
            throw CursorError.unauthorized
        }
        let usage = try await fetch(
            token: credentials.accessToken, credentials: credentials, now: now)
        try Task.checkCancellation()
        return usage
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

}
