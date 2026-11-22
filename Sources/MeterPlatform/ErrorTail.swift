import Foundation
import MeterDomain

/// The last bytes that a child process wrote to stderr, for a short error message.
struct ErrorTail: Sendable {
    let limit: Int
    private(set) var bytes = Data()
    /// The cut that keeps the limit split a word. The first word of the tail is then the end
    /// of a longer word, such as the end of a token, which no redaction rule can find.
    private var startsInsideWord = false

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append(_ chunk: Data) {
        bytes.append(chunk)
        guard bytes.count > limit else { return }
        let start = bytes.index(bytes.endIndex, offsetBy: -limit)
        startsInsideWord = !Self.isSpace(bytes[bytes.index(before: start)])
        bytes = Data(bytes[start...])
    }

    /// The last non-empty line, trimmed and redacted, or nil. A split first word is left out.
    var lastLine: String? {
        let text = sanitizedText
        let line = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return line.map(Redactor.redact)
    }

    /// The kept tail, trimmed and redacted, or nil when empty. A split first word is left out.
    var fullText: String? {
        let trimmed = sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Redactor.redact(trimmed)
    }

    private var sanitizedText: String {
        let text = String(decoding: bytes, as: UTF8.self)
        guard startsInsideWord else { return text }
        let rest = text.drop { !$0.isWhitespace }
        return String(rest)
    }

    /// ASCII white space, the only white space that a byte can be.
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }
}
