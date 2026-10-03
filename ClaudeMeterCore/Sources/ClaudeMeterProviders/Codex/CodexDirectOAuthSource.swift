import ClaudeMeterCore
import Foundation

public final class CodexDirectOAuthSource: CodexUsageSourceFetching, @unchecked Sendable {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let resetCreditsURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private static let resetCreditsTaskBudget = Timeout.TaskBudget(limit: 16)

    private let transport: any HTTPTransport
    private let credentialsLoader: @Sendable () throws -> CodexOAuthCredentials
    private let resetCreditsTimeout: TimeInterval

    public init(
        transport: any HTTPTransport = ProviderHTTPClient.shared,
        credentialsLoader: @escaping @Sendable () throws -> CodexOAuthCredentials = {
            try CodexOAuthCredentialsStore.load()
        },
        resetCreditsTimeout: TimeInterval = 4
    ) {
        self.transport = transport
        self.credentialsLoader = credentialsLoader
        self.resetCreditsTimeout = resetCreditsTimeout
    }

    public func fetchUsage(now: Date = Date()) async throws -> CodexUsage {
        try Task.checkCancellation()
        let credentials = try credentialsLoader()
        try Task.checkCancellation()
        if CodexOAuthCredentialsStore.accessTokenNeedsRecovery(credentials.accessToken, now: now) {
            throw CodexOAuthCredentialsError.expiredAccessToken
        }
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeMeter", forHTTPHeaderField: "User-Agent")
        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, http) = try await transport.send(request, retry: .none)
        switch http.statusCode {
        case 200...299:
            let response = try JSONDecoder().decode(CodexOAuthUsageResponse.self, from: data)
            var usage = try response.usage(accountEmail: nil, now: now, source: .directOAuth)
            try Task.checkCancellation()
            if let resets = usage.rateLimitResets, resets.availableCount > 0 {
                usage.rateLimitResets?.credits = try await fetchResetCredits(
                    credentials: credentials, availableCount: resets.availableCount, now: now)
            }
            try Task.checkCancellation()
            return usage
        case 401, 403:
            throw CodexUsageError.loginRequired
        default:
            throw CodexUsageError.httpError(http.statusCode)
        }
    }

    private func fetchResetCredits(
        credentials: CodexOAuthCredentials, availableCount: Int, now: Date
    ) async throws -> [CodexRateLimitResetCredit]? {
        var request = URLRequest(url: Self.resetCreditsURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = resetCreditsTimeout
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeMeter", forHTTPHeaderField: "User-Agent")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let detailsRequest = request
        let transport = transport
        do {
            let (data, http) = try await Timeout.run(
                seconds: resetCreditsTimeout, budget: Self.resetCreditsTaskBudget
            ) {
                try Task.checkCancellation()
                return try await transport.send(detailsRequest, retry: .none)
            }
            try Task.checkCancellation()
            guard (200...299).contains(http.statusCode) else { return nil }
            let response = try JSONDecoder().decode(CodexOAuthResetCreditsResponse.self, from: data)
            // A reset may be granted or consumed between the two requests. Never
            // attach a different inventory to the quota response's authoritative count.
            guard response.availableCount == availableCount else { return nil }
            return response.availableCredits(asOf: now)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // Optional details must not fail valid quota or start auth recovery.
            return nil
        }
    }
}
