import Foundation
import MeterDomain
import MeterPlatform

/// Counts tokens per local day in Cursor's usage export.
///
/// The four token columns are disjoint, so their sum is the row's token count. Prices and
/// models never decide what counts. A header-only export is a real zero for the range.
enum CursorTokenCSV {
    static let dateColumn = "Date"
    static let tokenColumns = [
        "Input (w/ Cache Write)", "Input (w/o Cache Write)", "Cache Read", "Output Tokens",
    ]
    /// Rows after this many are not counted, and the history is partial.
    static let maxRecords = 100_000

    /// Throws ``CursorFailure/unexpectedResponse`` for a missing header or malformed CSV, and
    /// `CancellationError`.
    static func history(
        _ data: Data, range: DateInterval, now: Date, calendar: Calendar,
        maxRecords: Int = maxRecords
    ) throws -> TokenHistory {
        var columns: [String: Int]?
        var records = 0
        var daily: [Date: Int64] = [:]
        var isPartial = false
        let plainDate = plainDateFormatter(calendar.timeZone)
        do {
            try CSVRecords.read(data) { row in
                guard let columns else {
                    columns = try header(row)
                    return true
                }
                records += 1
                guard records <= maxRecords else {
                    isPartial = true
                    return false
                }
                guard row.count == columns.count,
                    let date = date(row[columns[dateColumn] ?? 0], plainDate: plainDate),
                    let count = tokens(in: row, columns: columns)
                else {
                    isPartial = true
                    return true
                }
                if date < range.start { return true }
                guard date <= now else {
                    isPartial = true
                    return true
                }
                let day = calendar.startOfDay(for: date)
                let (sum, overflow) = daily[day, default: 0].addingReportingOverflow(count)
                if overflow { isPartial = true } else { daily[day] = sum }
                return true
            }
        } catch is CSVRecords.MalformedError {
            throw CursorFailure.unexpectedResponse
        }
        guard columns != nil else { throw CursorFailure.unexpectedResponse }
        return TokenHistory(
            dailyTokens: daily, coverageStart: range.start, observedAt: now,
            timeZoneID: calendar.timeZone.identifier, hasRecords: true, isPartial: isPartial)
    }

    /// Column positions by trimmed name. Names must be unique and include every needed column.
    private static func header(_ row: [String]) throws -> [String: Int] {
        let names = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(names).count == names.count,
            ([dateColumn] + tokenColumns).allSatisfy(names.contains)
        else { throw CSVRecords.MalformedError() }
        return Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
    }

    /// An ISO-8601 date, an epoch in seconds or milliseconds, or `yyyy-MM-dd HH:mm:ss` local.
    private static func date(_ field: String, plainDate: DateFormatter) -> Date? {
        let text = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let date =
            DateParsing.iso8601(text) ?? NumericText.double(text).flatMap(DateParsing.epoch)
            ?? plainDate.date(from: text)
        return DateBounds.validated(date)
    }

    private static func tokens(in row: [String], columns: [String: Int]) -> Int64? {
        var total: Int64 = 0
        for name in tokenColumns {
            guard let index = columns[name], let value = integer(row[index]) else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    /// A non-negative integer, with optional thousands separators in strict groups of three.
    /// An empty field is zero.
    static func integer(_ field: String) -> Int64? {
        let text = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return 0 }
        let groups = text.split(separator: ",", omittingEmptySubsequences: false)
        let isDigits = { (group: Substring) in
            !group.isEmpty && group.utf8.allSatisfy { (48...57).contains($0) }
        }
        guard groups.allSatisfy(isDigits),
            groups.count == 1
                || (groups[0].count <= 3 && groups.dropFirst().allSatisfy { $0.count == 3 })
        else { return nil }
        return Int64(groups.joined())
    }

    private static func plainDateFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
}
