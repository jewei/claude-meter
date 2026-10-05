import Foundation
import MeterDomain
import MeterPlatform

/// Cursor's dashboard endpoints. They are internal to Cursor and can change without notice.
enum CursorAPI {
    static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    static let planURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
    static let exportURL = URL(
        string: "https://cursor.com/api/dashboard/export-usage-events-csv")!

    static let usageDeadline: Duration = .seconds(20)
    /// The plan name is optional, so its request gets less time.
    static let planDeadline: Duration = .seconds(10)
    /// The app gives `reconcile` and one history read ``appHistoryLimit`` together. They read
    /// the credentials three times, at most 2 s each
    /// (``CursorCredentialStore/historyReadTimeout``), so 2 + 2 + 10 + 2 = 16 s leaves at
    /// least ``parseReserve`` to parse the export.
    static let exportDeadline: Duration = .seconds(10)
    /// The app's limit for `reconcile` and one history read together. It is
    /// `UsageStore.historyDeadline` in MeterApp, which a provider cannot import, so a MeterApp
    /// test checks that both are the same.
    static let appHistoryLimit: Duration = .seconds(20)
    /// The time that must stay to parse the export after the credential reads and the export.
    static let parseReserve: Duration = .seconds(4)

    /// A Connect RPC call with an empty JSON body. Cursor has its own rate limits, so the
    /// request is never retried.
    static func connectRequest(_ url: URL, token: String, deadline: Duration) -> HTTPRequest {
        HTTPRequest(
            .post, url: url,
            headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
            ],
            body: Data("{}".utf8), retry: .never, deadline: deadline)
    }

    /// The token export for `range`. The dashboard accepts only its session cookie, which is
    /// built from the user ID in the token's `sub` claim and the token itself. The cookie
    /// lives in this request only.
    static func exportRequest(
        credentials: CursorCredentials, range: DateInterval, now: Date
    ) throws(CursorFailure) -> HTTPRequest {
        let token = credentials.accessToken
        // The user ID is the text after the last `|`, even when that text is empty, so
        // `auth0|` is an unexpected token and never becomes the user `auth0`.
        guard let subject = credentials.subject,
            let userID = subject.split(separator: "|", omittingEmptySubsequences: false).last
                .map(String.init),
            !userID.isEmpty, userID.utf8.allSatisfy(isUserIDByte),
            token.utf8.allSatisfy({ isUserIDByte($0) || $0 == UInt8(ascii: ".") })
        else { throw .unexpectedToken }
        guard let start = milliseconds(range.start), let end = milliseconds(now) else {
            throw .invalidDate
        }
        let url = exportURL.appending(queryItems: [
            URLQueryItem(name: "startDate", value: String(start)),
            URLQueryItem(name: "endDate", value: String(end)),
            URLQueryItem(name: "strategy", value: "tokens"),
        ])
        return HTTPRequest(
            .get, url: url,
            headers: [
                "Accept": "text/csv",
                "Origin": "https://cursor.com",
                "Cookie": "WorkosCursorSessionToken=\(userID)%3A%3A\(token)",
            ],
            retry: .never, deadline: exportDeadline)
    }

    /// Sends `request` and returns the body of an HTTP 200 response.
    ///
    /// Throws `CancellationError` when the task is cancelled, and ``CursorFailure`` for every
    /// other failure. HTTP 429 throws its ``CursorFailure`` also when the task is cancelled after
    /// the response, so the caller can still hold the login.
    static func send(_ request: HTTPRequest, http: any HTTPClient, now: Date) async throws -> Data {
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw CursorFailure(transport: error)
        }
        if response.status != 429 { try Task.checkCancellation() }
        guard response.status == 200 else {
            throw CursorFailure(
                status: response.status, retryAfter: response.header("retry-after"), now: now)
        }
        return response.body
    }

    private static func isUserIDByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }

    /// Whole milliseconds since 1970, or nil for a date outside `DateBounds`.
    private static func milliseconds(_ date: Date) -> Int64? {
        guard DateBounds.contains(date) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
