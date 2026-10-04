import Foundation

/// Splits CSV bytes into rows of fields, with RFC 4180 quoting and bounds on every row.
///
/// - A leading UTF-8 byte order mark is skipped.
/// - `,` ends a field. LF, CR, or CR LF ends a row.
/// - A `"` opens a quoted field only at the start of the field. Inside quotes, `""` is one
///   quote, and commas and line breaks are data.
/// - Rows with one empty field (blank lines) are skipped.
/// - Text after a closing quote, a quote inside an unquoted field, an unterminated quote,
///   invalid UTF-8, a field above ``maxFieldBytes``, or a row above ``maxFields`` is malformed.
enum CSVRecords {
    struct MalformedError: Error, Equatable {}

    static let maxFieldBytes = 32 * 1024
    static let maxFields = 100
    /// Cancellation is checked once per this many bytes.
    static let cancellationInterval = 64 * 1024

    /// Calls `consume` for each row until it returns false. Throws ``MalformedError`` or
    /// `CancellationError`, or what `consume` throws.
    static func read(_ data: Data, _ consume: ([String]) throws -> Bool) throws {
        try withoutActuallyEscaping(consume) { consume in
            var reader = Reader(consume: consume)
            let bytes = [UInt8](data)
            var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
            // A byte pair such as `""` can step over a multiple of the interval, so the check
            // runs once in each block, not at exact multiples.
            var checkedBlock = -1
            while index < bytes.count {
                if index / cancellationInterval != checkedBlock {
                    checkedBlock = index / cancellationInterval
                    try Task.checkCancellation()
                }
                let byte = bytes[index]
                index += 1
                let next = index < bytes.count ? bytes[index] : nil
                switch try reader.accept(byte, next: next) {
                case .continue: break
                case .skipNext: index += 1
                case .stop: return
                }
            }
            try reader.finish()
        }
    }

    private struct Reader {
        enum Step {
            case `continue`
            /// The next byte was consumed with this one, as in `""` or CR LF.
            case skipNext
            case stop
        }

        let consume: ([String]) throws -> Bool
        var row: [String] = []
        var field: [UInt8] = []
        var isQuoted = false
        var closedQuote = false

        mutating func accept(_ byte: UInt8, next: UInt8?) throws -> Step {
            let quote = UInt8(ascii: "\"")
            if isQuoted {
                if byte != quote {
                    try append(byte)
                } else if next == quote {
                    try append(quote)
                    return .skipNext
                } else {
                    isQuoted = false
                    closedQuote = true
                }
                return .continue
            }
            switch byte {
            case UInt8(ascii: ","):
                try finishField()
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                let keepsReading = try finishRow()
                guard keepsReading else { return .stop }
                return byte == UInt8(ascii: "\r") && next == UInt8(ascii: "\n")
                    ? .skipNext : .continue
            case quote where field.isEmpty && !closedQuote:
                isQuoted = true
            default:
                guard !closedQuote, byte != quote else { throw MalformedError() }
                try append(byte)
            }
            return .continue
        }

        mutating func finish() throws {
            guard !isQuoted else { throw MalformedError() }
            if !field.isEmpty || !row.isEmpty || closedQuote {
                _ = try finishRow()
            }
        }

        private mutating func append(_ byte: UInt8) throws {
            guard field.count < CSVRecords.maxFieldBytes else { throw MalformedError() }
            field.append(byte)
        }

        private mutating func finishField() throws {
            guard let value = String(bytes: field, encoding: .utf8) else { throw MalformedError() }
            row.append(value)
            field.removeAll(keepingCapacity: true)
            closedQuote = false
            guard row.count <= CSVRecords.maxFields else { throw MalformedError() }
        }

        /// Returns whether reading continues.
        private mutating func finishRow() throws -> Bool {
            try finishField()
            defer { row.removeAll(keepingCapacity: true) }
            guard row.count > 1 || !row[0].isEmpty else { return true }
            return try consume(row)
        }
    }
}
