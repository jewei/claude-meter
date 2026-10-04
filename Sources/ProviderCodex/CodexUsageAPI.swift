import Foundation
import MeterDomain
import MeterPlatform

/// The two read-only ChatGPT endpoints that report Codex quota.
struct CodexUsageAPI: Sendable {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    let http: any HTTPClient
    /// The limit for the optional reset-credit details request.
    let resetDetailsLimit: Duration

    /// Sends `GET wham/usage` once. HTTP 401 and 403 throw ``CodexError/loginRequired``.
    /// When the response reports reset credits, one more request reads their details.
    /// Throws ``CodexError``, or `CancellationError` only when this refresh was cancelled.
    func quota(with credentials: CodexCredentials, now: Date) async throws -> CodexQuota {
        let request = HTTPRequest(
            .get, url: Self.usageURL, headers: Self.headers(for: credentials), retry: .never)
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch is CancellationError where Task.isCancelled {
            throw CancellationError()
        } catch is CancellationError {
            // The transport cancelled the request on its own, for example after a
            // `URLError.cancelled` that this refresh did not cause.
            throw CodexError.network("The request was cancelled.")
        } catch {
            throw CodexError.network(error.localizedDescription)
        }
        switch response.status {
        case 200..<300:
            break
        case 401, 403:
            throw CodexError.loginRequired
        default:
            let delay = RetryAfter.delay(response.header("retry-after"), now: now)
            throw CodexError.httpStatus(
                response.status, retryAt: delay.map { now.addingTimeInterval($0) })
        }
        var quota = try CodexUsageResponse.quota(from: response.body)
        if let count = quota.resetCount, count > 0 {
            quota.resets =
                try await resetDetails(with: credentials, expectedCount: count, now: now) ?? []
        }
        return quota
    }

    /// Reads reset-credit details once, with no retries, within ``resetDetailsLimit``.
    ///
    /// Any failure returns nil: the quota and the count stay, and recovery never starts.
    /// Only cancellation of the caller throws.
    private func resetDetails(
        with credentials: CodexCredentials, expectedCount: Int, now: Date
    ) async throws -> [ResetAllowance.Reset]? {
        var headers = Self.headers(for: credentials)
        headers["OpenAI-Beta"] = "codex-1"
        headers["originator"] = "Codex Desktop"
        let request = HTTPRequest(
            .get, url: Self.resetCreditsURL, headers: headers, retry: .never,
            deadline: resetDetailsLimit)
        do {
            let response = try await withDeadline(resetDetailsLimit) { [http] in
                try await http.send(request)
            }
            guard response.isSuccess else { return nil }
            return CodexUsageResponse.resets(
                from: response.body, expectedCount: expectedCount, now: now)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    static func headers(for credentials: CodexCredentials) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
            "User-Agent": "ClaudeMeter",
        ]
        if let accountID = credentials.accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return headers
    }
}
