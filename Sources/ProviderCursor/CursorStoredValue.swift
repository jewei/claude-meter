import Foundation

/// Decodes one value that Cursor stored in `state.vscdb` or in the Keychain.
///
/// Cursor writes UTF-8 text, but some values arrive as UTF-16 blobs, and some are JSON string
/// literals with surrounding quotes.
enum CursorStoredValue {
    /// The trimmed, unquoted text, or nil when the bytes are not text or the text is empty.
    static func text(_ data: Data) -> String? {
        guard let decoded = decode(data) else { return nil }
        let value = unquote(decoded)
        return value.isEmpty ? nil : value
    }

    /// UTF-16LE without a byte order mark is tried first, because UTF-8 would accept its NUL
    /// bytes as part of the text. Only ASCII characters qualify for that form.
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let isASCIIUTF16 =
            !bytes.isEmpty && bytes.count.isMultiple(of: 2)
            && stride(from: 0, to: bytes.count, by: 2).allSatisfy { index in
                bytes[index] > 0 && bytes[index] < 128 && bytes[index + 1] == 0
            }
        if isASCIIUTF16 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Trims whitespace and removes one pair of surrounding double quotes. Inner text stays.
    static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }
}
