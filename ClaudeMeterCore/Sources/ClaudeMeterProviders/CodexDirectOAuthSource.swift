import ClaudeMeterCore
import Foundation

public final class CodexDirectOAuthSource: CodexUsageSourceFetching, @unchecked Sendable {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let transport: any HTTPTransport
    private let credentialsLoader: @Sendable () throws -> CodexOAuthCredentials

    public init(
        transport: any HTTPTransport = ProviderHTTPClient.shared,
        credentialsLoader: @escaping @Sendable () throws -> CodexOAuthCredentials = {
            try CodexOAuthCredentialsStore.load()
        }
    ) {
        self.transport = transport
        self.credentialsLoader = credentialsLoader
    }

    public func isAvailable() async -> Bool {
        (try? credentialsLoader()) != nil
    }

    public func fetchUsage(now: Date = Date()) async throws -> CodexUsage {
        let credentials = try credentialsLoader()
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
            return try response.usage(accountEmail: nil, now: now, source: .directOAuth)
        case 401, 403:
            throw CodexUsageError.loginRequired
        default:
            throw CodexUsageError.httpError(http.statusCode)
        }
    }
}
