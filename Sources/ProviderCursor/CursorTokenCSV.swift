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

    private struct HeaderLayout {
        let columnCount: Int
        let dateIndex: Int
        let tokenIndices: [Int]
    }

    /// Throws ``CursorFailure/unexpectedResponse`` for a missing header or malformed CSV, and
    /// `CancellationError`.
    static func history(
        _ data: Data, range: DateInterval, now: Date, calendar: Calendar,
        maxRecords: Int = maxRecords
    ) throws -> TokenHistory {
        var layout: HeaderLayout?
        var records = 0
        var daily: [Date: Int64] = [:]
        var isPartial = false
        let plainDate = plainDateFormatter(calendar.timeZone)
        let dayBounds = precomputedDayBounds(from: range.start, through: now, calendar: calendar)
        var lastDayIndex = max(0, dayBounds.count - 1)
        do {
            try CSVRecords.read(data) { row in
                guard let layout else {
                    layout = try header(row)
                    return true
                }
                records += 1
                guard records <= maxRecords else {
                    isPartial = true
                    return false
                }
                guard row.count == layout.columnCount,
                    let date = date(row[layout.dateIndex], plainDate: plainDate),
                    let count = tokens(in: row, indices: layout.tokenIndices)
                else {
                    isPartial = true
                    return true
                }
                if date < range.start { return true }
                guard date <= now else {
                    isPartial = true
                    return true
                }
                let day = dayStart(
                    for: date, bounds: dayBounds, lastIndex: &lastDayIndex, calendar: calendar)
                let (sum, overflow) = daily[day, default: 0].addingReportingOverflow(count)
                if overflow { isPartial = true } else { daily[day] = sum }
                return true
            }
        } catch is CSVRecords.MalformedError {
            throw CursorFailure.unexpectedResponse
        }
        guard layout != nil else { throw CursorFailure.unexpectedResponse }
        return TokenHistory(
            dailyTokens: daily, coverageStart: range.start, observedAt: now,
            timeZoneID: calendar.timeZone.identifier, hasRecords: true, isPartial: isPartial)
    }

    /// Column positions by trimmed name. Names must be unique and include every needed column.
    private static func header(_ row: [String]) throws -> HeaderLayout {
        let names = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var map: [String: Int] = Dictionary(minimumCapacity: names.count)
        for (index, name) in names.enumerated() {
            guard map.updateValue(index, forKey: name) == nil else {
                throw CSVRecords.MalformedError()
            }
        }
        guard let dateIndex = map[dateColumn] else { throw CSVRecords.MalformedError() }
        var tokenIndices: [Int] = []
        tokenIndices.reserveCapacity(tokenColumns.count)
        for name in tokenColumns {
            guard let index = map[name] else { throw CSVRecords.MalformedError() }
            tokenIndices.append(index)
        }
        return HeaderLayout(
            columnCount: names.count, dateIndex: dateIndex, tokenIndices: tokenIndices)
    }

    /// An ISO-8601 date, an epoch in seconds or milliseconds, or `yyyy-MM-dd HH:mm:ss` local.
    private static func date(_ field: String, plainDate: DateFormatter) -> Date? {
        if let parsed = DateParsing.iso8601(field) { return parsed }
        let text = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = NumericText.double(text).flatMap(DateParsing.epoch) ?? plainDate.date(from: text)
        return DateBounds.validated(date)
    }

    private static func tokens(in row: [String], indices: [Int]) -> Int64? {
        var total: Int64 = 0
        for index in indices {
            guard let value = integer(row[index]) else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    /// A non-negative integer, with optional thousands separators in strict groups of three.
    /// An empty field is zero. Parses UTF-8 bytes directly without intermediate allocations.
    static func integer(_ field: String) -> Int64? {
        var bytes = field.utf8[...]
        while let first = bytes.first, isWhitespace(first) { bytes = bytes.dropFirst() }
        while let last = bytes.last, isWhitespace(last) { bytes = bytes.dropLast() }
        if bytes.isEmpty { return 0 }

        var value: Int64 = 0
        var hasComma = false
        var groupDigits = 0
        for byte in bytes {
            if byte >= 0x30, byte <= 0x39 {
                let digit = Int64(byte - 0x30)
                let (multiplied, mOverflow) = value.multipliedReportingOverflow(by: 10)
                guard !mOverflow else { return nil }
                let (sum, aOverflow) = multiplied.addingReportingOverflow(digit)
                guard !aOverflow else { return nil }
                value = sum
                groupDigits += 1
            } else if byte == 0x2C {
                if !hasComma {
                    guard groupDigits >= 1, groupDigits <= 3 else { return nil }
                    hasComma = true
                } else {
                    guard groupDigits == 3 else { return nil }
                }
                groupDigits = 0
            } else {
                return nil
            }
        }
        if hasComma {
            guard groupDigits == 3 else { return nil }
        } else {
            guard groupDigits > 0 else { return nil }
        }
        return value
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func precomputedDayBounds(
        from start: Date, through now: Date, calendar: Calendar
    ) -> [(start: Date, end: Date)] {
        var bounds: [(start: Date, end: Date)] = []
        var dayStart = start
        for _ in 0..<8 where dayStart <= now {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            bounds.append((start: dayStart, end: nextDay))
            dayStart = nextDay
        }
        return bounds
    }

    private static func dayStart(
        for date: Date, bounds: [(start: Date, end: Date)], lastIndex: inout Int, calendar: Calendar
    ) -> Date {
        if !bounds.isEmpty {
            let cached = bounds[lastIndex]
            if date >= cached.start, date < cached.end { return cached.start }
            for index in bounds.indices.reversed() {
                let bound = bounds[index]
                if date >= bound.start, date < bound.end {
                    lastIndex = index
                    return bound.start
                }
            }
        }
        return calendar.startOfDay(for: date)
    }

    private static func plainDateFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
}
