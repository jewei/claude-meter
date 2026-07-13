import Foundation

/// Fetches Grok Build credit usage from the unofficial cli-chat-proxy billing
/// endpoint using the CLI's cached bearer token. Read-only: never refreshes or
/// writes credentials. 401/403 means the token expired or was revoked — the
/// CLI refreshes it the next time the user runs `grok`.
public final class GrokUsageProvider: @unchecked Sendable {
    private static let billingURL = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    private let transport: any HTTPTransport
    private let credentialsLoader: @Sendable (Date) throws -> GrokCredentials

    public init(
        transport: any HTTPTransport = ProviderHTTPClient.shared,
        credentialsLoader: @escaping @Sendable (Date) throws -> GrokCredentials = { now in
            try GrokAuthStore.load(now: now)
        }
    ) {
        self.transport = transport
        self.credentialsLoader = credentialsLoader
    }

    public func isAvailable() async -> Bool {
        (try? credentialsLoader(Date())) != nil
    }

    public func fetchUsage(now: Date = Date()) async throws -> GrokUsage {
        let credentials = try credentialsLoader(now)
        var request = URLRequest(url: Self.billingURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeMeter", forHTTPHeaderField: "User-Agent")

        let (data, http) = try await transport.send(request, retry: .transient)
        switch http.statusCode {
        case 200...299:
            let response = try JSONDecoder().decode(GrokBillingResponse.self, from: data)
            return try response.usage(accountEmail: credentials.email, now: now)
        case 401, 403:
            throw GrokUsageError.loginRequired
        default:
            throw GrokUsageError.httpError(http.statusCode)
        }
    }
}
