import ClaudeMeterCore
import Foundation

/// Uses Cursor's account export with the app's existing, read-only credentials.
public final class CursorTokenUsageSource: TokenUsageSource, Sendable {
    public let id: ProviderID = .cursor
    private let transport: any HTTPTransport
    private let credentials: @Sendable () throws -> CursorCredentials?
    private let credentialBudget = Timeout.TaskBudget(limit: 2)
    @MainActor private var acceptedStamp: String?
    @MainActor private var pending: (id: UUID, stamp: String?)?

    public init(
        transport: any HTTPTransport = ProviderHTTPClient.shared,
        credentials: @escaping @Sendable () throws -> CursorCredentials? = {
            try CursorTokenStore.detect()
        }
    ) {
        self.transport = transport
        self.credentials = credentials
    }

    @MainActor public func validatePrevious(
        _ previous: TokenUsageSnapshot?, refreshID: UUID
    ) async throws -> TokenUsageSnapshot? {
        pending = (refreshID, nil)
        let owner: String
        do {
            owner = try await Timeout.run(seconds: 2, budget: credentialBudget) { [self] in
                Self.stamp(try load())
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A failed ownership check cannot establish that the previous login
            // still owns this account export.
            throw UsageProviderFailure(error, retainsLastGood: false)
        }
        try Task.checkCancellation()
        guard pending?.id == refreshID else { throw CancellationError() }
        pending = (refreshID, owner)
        return owner == acceptedStamp ? previous : nil
    }

    public func fetch(now: Date, refreshID: UUID) async throws -> TokenUsageSnapshot {
        let credential: CursorCredentials
        do { credential = try load() } catch {
            throw UsageProviderFailure(error, retainsLastGood: false)
        }
        let stamp = Self.stamp(credential)
        guard await matches(stamp, refreshID: refreshID) else {
            throw UsageProviderFailure(TokenHistoryError.signInChanged, retainsLastGood: false)
        }
        do {
            if let expiry = CursorTokenStore.expiry(of: credential.accessToken), expiry <= now {
                throw CursorError.unauthorized
            }
            let request = try Self.request(
                token: credential.accessToken, now: now, calendar: .current)
            let (data, response) = try await transport.send(request)
            switch response.statusCode {
            case 200: break
            case 401: throw CursorError.unauthorized
            case 403: throw CursorError.forbidden
            default: throw CursorError.httpError(response.statusCode)
            }
            let result = try CursorTokenCSV.parse(data, now: now)
            try Task.checkCancellation()
            guard Self.stamp(try load()) == stamp else { throw TokenHistoryError.signInChanged }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let stillOwned = (try? Self.stamp(load())) == stamp
            let retains =
                stillOwned && (error as? TokenHistoryError) != .signInChanged
                && (error as? CursorError) != .unauthorized && (error as? CursorError) != .forbidden
            throw UsageProviderFailure(error, retainsLastGood: retains)
        }
    }

    @MainActor private func matches(_ stamp: String, refreshID: UUID) -> Bool {
        pending?.id == refreshID && pending?.stamp == stamp
    }

    @MainActor public func didAccept(_ snapshot: TokenUsageSnapshot, refreshID: UUID) {
        guard pending?.id == refreshID else { return }
        acceptedStamp = pending?.stamp
    }

    private func load() throws -> CursorCredentials {
        guard let value = try credentials() else { throw CursorError.notDetected }
        return value
    }

    private static func stamp(_ credential: CursorCredentials) -> String {
        CredentialBoundProvider<CursorCredentials>.digest([
            credential.accessToken, credential.refreshToken ?? "",
        ])
    }

    static func request(token: String, now: Date, calendar: Calendar) throws -> URLRequest {
        guard let interval = TokenUsagePeriod.lastSevenDays.interval(asOf: now, calendar: calendar),
            let payload = token.split(separator: ".").dropFirst().first,
            let data = Base64URL.decode(String(payload)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let subject = json["sub"] as? String,
            let userID = subject.split(separator: "|").last, !userID.isEmpty,
            userID.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            }),
            token.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46
            })
        else { throw CursorError.unauthorized }
        var components = URLComponents(
            string: "https://cursor.com/api/dashboard/export-usage-events-csv")!
        components.queryItems = [
            URLQueryItem(
                name: "startDate", value: String(Int64(interval.start.timeIntervalSince1970 * 1000))
            ),
            URLQueryItem(name: "endDate", value: String(Int64(now.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "strategy", value: "tokens"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("text/csv", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "WorkosCursorSessionToken=\(userID)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        return request
    }
}

enum CursorTokenCSV {
    static let tokenColumns = [
        "Input (w/ Cache Write)", "Input (w/o Cache Write)", "Cache Read", "Output Tokens",
    ]

    static func parse(_ data: Data, now: Date, calendar: Calendar = .current) throws
        -> TokenUsageSnapshot
    {
        var totals = try TokenDayAccumulator(now: now, calendar: calendar)
        let plainDate = DateFormatter()
        plainDate.locale = Locale(identifier: "en_US_POSIX")
        plainDate.timeZone = calendar.timeZone
        plainDate.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var header: [String: Int]?
        var records = 0
        try readRecords(data) { row in
            if header == nil {
                let names = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard Set(names).count == names.count,
                    (["Date"] + tokenColumns).allSatisfy({ names.contains($0) })
                else { throw TokenHistoryError.invalidCSV }
                header = Dictionary(
                    uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
                return
            }
            guard let header else { return }
            records += 1
            guard records <= 100_000 else { throw TokenHistoryError.invalidCSV }
            guard row.count == header.count else {
                totals.isPartial = true
                return
            }
            let rawDate = row[header["Date"]!].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let date = parseEpochOrISODate(rawDate) ?? plainDate.date(from: rawDate),
                PersistedDateBounds.contains(date),
                let count = TokenJSON.sum(tokenColumns.map { integer(row[header[$0]!]) })
            else {
                totals.isPartial = true
                return
            }
            totals.add(TokenEvent(date: date, count: count))
        }
        guard header != nil else { throw TokenHistoryError.invalidCSV }
        // A successful empty export establishes zero account usage in the range.
        return totals.snapshot(provider: .cursor, hasRecords: true)
    }

    private static func integer(_ value: String) -> Int64? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return 0 }
        let groups = value.split(separator: ",", omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
            groups.count == 1
                || groups[0].count <= 3 && groups.dropFirst().allSatisfy({ $0.count == 3 })
        else { return nil }
        return Int64(groups.joined())
    }

    /// CSV fields can contain escaped quotes, commas, or newlines. Keep one row only.
    private static func readRecords(_ data: Data, consume: ([String]) throws -> Void) throws {
        let bytes = Array(data)
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var closedQuote = false
        func finishField() throws {
            guard let value = String(bytes: field, encoding: .utf8) else {
                throw TokenHistoryError.invalidCSV
            }
            row.append(value)
            field.removeAll(keepingCapacity: true)
            closedQuote = false
            guard row.count <= 100 else { throw TokenHistoryError.invalidCSV }
        }
        func finishRow() throws {
            try finishField()
            if row.count > 1 || !row[0].isEmpty { try consume(row) }
            row.removeAll(keepingCapacity: true)
        }
        while index < bytes.count {
            if index % 65536 == 0 { try Task.checkCancellation() }
            let byte = bytes[index]
            index += 1
            if quoted {
                if byte == 34 {
                    if index < bytes.count, bytes[index] == 34 {
                        field.append(34)
                        index += 1
                    } else {
                        quoted = false
                        closedQuote = true
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == 44 {
                try finishField()
            } else if byte == 10 || byte == 13 {
                if byte == 13, index < bytes.count, bytes[index] == 10 { index += 1 }
                try finishRow()
            } else if byte == 34, field.isEmpty, !closedQuote {
                quoted = true
            } else {
                guard !closedQuote, byte != 34 else { throw TokenHistoryError.invalidCSV }
                field.append(byte)
            }
            guard field.count <= 32 * 1024 else { throw TokenHistoryError.invalidCSV }
        }
        guard !quoted else { throw TokenHistoryError.invalidCSV }
        if !field.isEmpty || !row.isEmpty || closedQuote { try finishRow() }
    }
}
