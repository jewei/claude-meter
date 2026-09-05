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
/// Reads the locally stored token (`CursorTokenStore`), calls the Connect-RPC
/// `GetCurrentPeriodUsage` endpoint, and transparently refreshes the access token
/// on expiry or a 401. Refreshed tokens are cached in memory for the app session;
/// we never write back to Cursor's own store.
public final class CursorUsageProvider: @unchecked Sendable {

    private struct SourceTokenIdentity: Hashable {
        let accessToken: String
        let refreshToken: String?
    }

    private struct RefreshKey: Hashable {
        let sourceTokenIdentity: SourceTokenIdentity
        let sourceGeneration: UInt64
        let refreshToken: String
    }

    private struct CacheLease {
        let sourceTokenIdentity: SourceTokenIdentity
        let sourceGeneration: UInt64
        let revision: UInt64
    }

    private struct TokenSelection {
        let accessToken: String
        let refreshToken: String?
        let lease: CacheLease
    }

    private static let baseURL = "https://api2.cursor.sh"
    private static let tokenURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static let usagePath = "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    private static let planInfoPath = "/aiserver.v1.DashboardService/GetPlanInfo"

    private let transport: any HTTPTransport
    private let credentialsLoader: @Sendable () -> CursorCredentials?
    private let beforeRefreshCoordinator: (@Sendable () async -> Void)?
    private let refreshCoordinator =
        RefreshResultHandoffCoordinator<RefreshKey, RefreshResult>(
            maximumCompletedHandoffs: 8)
    private let stateQueue = DispatchQueue(label: "com.jewei.claudemeter.cursor-provider.state")
    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var cachedSourceTokenIdentity: SourceTokenIdentity?
    private var rejectedSourceTokenIdentity: SourceTokenIdentity?
    private var sourceGeneration: UInt64 = 0
    private var cacheRevision: UInt64 = 0

    public init(
        transport: any HTTPTransport = ProviderHTTPClient.shared,
        credentialsLoader: @escaping @Sendable () -> CursorCredentials? = {
            CursorTokenStore.detect()
        }
    ) {
        self.transport = transport
        self.credentialsLoader = credentialsLoader
        self.beforeRefreshCoordinator = nil
    }

    /// Test seam that suspends after token selection but before coordinator
    /// acquisition. Production callers use the public initializer above.
    init(
        transport: any HTTPTransport,
        credentialsLoader: @escaping @Sendable () -> CursorCredentials?,
        beforeRefreshCoordinator: @escaping @Sendable () async -> Void
    ) {
        self.transport = transport
        self.credentialsLoader = credentialsLoader
        self.beforeRefreshCoordinator = beforeRefreshCoordinator
    }

    public func fetchUsage(now: Date = Date()) async throws -> CursorUsage {
        guard let creds = credentialsLoader() else { throw CursorError.notDetected }
        let selection = reconcileCachedTokens(with: creds)
        let lease = selection.lease

        let refreshToken = selection.refreshToken
        var token = selection.accessToken
        var refreshChainWasRejected = false

        if CursorTokenStore.isExpiringSoon(token, now: now), let refreshToken {
            do {
                let refreshed = try await refresh(refreshToken, lease: lease)
                token = refreshed.accessToken
                guard
                    setCachedTokens(
                        access: refreshed.accessToken,
                        refresh: refreshed.refreshToken,
                        lease: lease)
                else { throw CancellationError() }
                markRefreshAdopted(refreshToken, lease: lease)
            } catch CursorError.unauthorized {
                // The access token can still be usable near its expiry. Probe it
                // once, but do not let this rejected lineage refresh again.
                refreshChainWasRejected = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A transient refresh failure does not prove that the current
                // access token is unusable. Probe it before clearing the chain.
            }
        }

        do {
            let usage = try await fetch(token: token, credentials: creds, now: now)
            if refreshChainWasRejected {
                guard invalidateCachedTokenLineage(lease: lease, rejected: true) else {
                    throw CancellationError()
                }
            } else {
                guard isCurrent(lease) else { throw CancellationError() }
            }
            return usage
        } catch CursorError.unauthorized {
            if token != creds.accessToken {
                // Keep the rotated refresh token while probing the source access
                // token. The source refresh token was consumed by the proactive
                // refresh and must not be retried if both access tokens return 401.
                guard clearCachedAccessToken(lease: lease) else { throw CancellationError() }
                do {
                    let usage = try await fetch(
                        token: creds.accessToken,
                        credentials: creds,
                        now: now)
                    if refreshChainWasRejected {
                        guard invalidateCachedTokenLineage(lease: lease, rejected: true) else {
                            throw CancellationError()
                        }
                    } else {
                        guard isCurrent(lease) else { throw CancellationError() }
                    }
                    return usage
                } catch CursorError.unauthorized {
                } catch {
                    if refreshChainWasRejected {
                        guard invalidateCachedTokenLineage(lease: lease, rejected: true) else {
                            throw CancellationError()
                        }
                    }
                    throw error
                }
            }
            guard isCurrent(lease) else { throw CancellationError() }
            if refreshChainWasRejected {
                guard invalidateCachedTokenLineage(lease: lease, rejected: true) else {
                    throw CancellationError()
                }
                throw CursorError.unauthorized
            }
            guard
                let refreshToken = selectedRefreshToken(
                    sourceRefreshToken: creds.refreshToken,
                    lease: lease)
            else {
                guard clearCachedTokens(lease: lease) else {
                    throw CancellationError()
                }
                throw CursorError.unauthorized
            }
            let refreshed: RefreshResult
            do {
                refreshed = try await refresh(refreshToken, lease: lease)
            } catch {
                guard
                    invalidateCachedTokenLineage(
                        lease: lease,
                        rejected: error as? CursorError == .unauthorized)
                else { throw CancellationError() }
                throw CursorError.unauthorized
            }
            guard
                setCachedTokens(
                    access: refreshed.accessToken,
                    refresh: refreshed.refreshToken,
                    lease: lease)
            else { throw CancellationError() }
            markRefreshAdopted(refreshToken, lease: lease)
            let usage = try await fetch(
                token: refreshed.accessToken,
                credentials: creds,
                now: now)
            guard isCurrent(lease) else { throw CancellationError() }
            return usage
        } catch {
            if refreshChainWasRejected {
                guard invalidateCachedTokenLineage(lease: lease, rejected: true) else {
                    throw CancellationError()
                }
            }
            throw error
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

    private func refresh(_ refreshToken: String, lease: CacheLease) async throws -> RefreshResult {
        if let beforeRefreshCoordinator { await beforeRefreshCoordinator() }
        let key = RefreshKey(
            sourceTokenIdentity: lease.sourceTokenIdentity,
            sourceGeneration: lease.sourceGeneration,
            refreshToken: refreshToken)
        return try await refreshCoordinator.run(key: key) { [self] in
            try await performRefresh(refreshToken)
        }
    }

    private func markRefreshAdopted(_ refreshToken: String, lease: CacheLease) {
        refreshCoordinator.adopted(
            key: RefreshKey(
                sourceTokenIdentity: lease.sourceTokenIdentity,
                sourceGeneration: lease.sourceGeneration,
                refreshToken: refreshToken))
    }

    private func performRefresh(_ refreshToken: String) async throws -> RefreshResult {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ])
        let (data, http) = try await transport.send(request)
        switch http.statusCode {
        case 200:
            break
        case 400, 401, 403:
            throw CursorError.unauthorized
        default:
            throw CursorError.httpError(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(CursorOAuthResponse.self, from: data)
        return RefreshResult(accessToken: decoded.accessToken, refreshToken: decoded.refreshToken)
    }

    // MARK: - In-memory token cache

    private func selectedRefreshToken(
        sourceRefreshToken: String?,
        lease: CacheLease
    ) -> String? {
        return stateQueue.sync {
            guard leaseIsCurrent(lease) else { return nil }
            guard rejectedSourceTokenIdentity != lease.sourceTokenIdentity else { return nil }
            return cachedRefreshToken ?? sourceRefreshToken
        }
    }

    private func clearCachedAccessToken(lease: CacheLease) -> Bool {
        stateQueue.sync {
            guard leaseIsCurrent(lease) else { return false }
            cachedAccessToken = nil
            return true
        }
    }

    private func clearCachedTokens(lease: CacheLease) -> Bool {
        stateQueue.sync {
            guard leaseIsCurrent(lease) else { return false }
            cachedAccessToken = nil
            cachedRefreshToken = nil
            return true
        }
    }

    /// Reject every retained handoff from the failed lineage before clearing its
    /// cache. A terminal token-endpoint response also blocks the unchanged local
    /// source until Cursor writes a new access/refresh identity.
    private func invalidateCachedTokenLineage(lease: CacheLease, rejected: Bool) -> Bool {
        stateQueue.sync {
            guard leaseIsCurrent(lease) else { return false }
            sourceGeneration &+= 1
            cachedAccessToken = nil
            cachedRefreshToken = nil
            rejectedSourceTokenIdentity = rejected ? lease.sourceTokenIdentity : nil
            return true
        }
    }

    @discardableResult
    private func setCachedTokens(access: String?, refresh: String?, lease: CacheLease) -> Bool {
        stateQueue.sync {
            guard leaseIsCurrent(lease) else { return false }
            cachedAccessToken = access
            rejectedSourceTokenIdentity = nil
            if let refresh {
                cachedRefreshToken = refresh
            } else if access == nil {
                cachedRefreshToken = nil
            }
            return true
        }
    }

    private func isCurrent(_ lease: CacheLease) -> Bool {
        stateQueue.sync { leaseIsCurrent(lease) }
    }

    /// Queue-local lease check. Call only from `stateQueue`.
    private func leaseIsCurrent(_ lease: CacheLease) -> Bool {
        cacheRevision == lease.revision
            && sourceGeneration == lease.sourceGeneration
            && cachedSourceTokenIdentity == lease.sourceTokenIdentity
    }

    /// Refreshed tokens belong to the locally detected source tokens that produced
    /// them. Cursor can update plan or email metadata without changing accounts, so
    /// metadata changes must not discard a rotated refresh-token chain.
    private func reconcileCachedTokens(with credentials: CursorCredentials) -> TokenSelection {
        let sourceTokenIdentity = SourceTokenIdentity(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken
        )
        return stateQueue.sync {
            // The newest fetch owns cache commits. This also prevents two
            // overlapping polls for one source from racing a rotated token chain.
            cacheRevision &+= 1
            if cachedSourceTokenIdentity != sourceTokenIdentity {
                sourceGeneration &+= 1
                cachedAccessToken = nil
                cachedRefreshToken = nil
                rejectedSourceTokenIdentity = nil
            }
            cachedSourceTokenIdentity = sourceTokenIdentity
            return TokenSelection(
                accessToken: cachedAccessToken ?? credentials.accessToken,
                refreshToken:
                    rejectedSourceTokenIdentity == sourceTokenIdentity
                    ? nil : cachedRefreshToken ?? credentials.refreshToken,
                lease: CacheLease(
                    sourceTokenIdentity: sourceTokenIdentity,
                    sourceGeneration: sourceGeneration,
                    revision: cacheRevision))
        }
    }
}
