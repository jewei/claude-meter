import Foundation

/// Finds the top-level `oauthAccount` object in the bytes of a `.claude.json`, chunk by chunk.
///
/// Claude Code keeps per-project state in the same file, so it can be very large. The scanner
/// follows only strings and nesting, never builds the whole document, and stops as soon as the
/// object is complete. It also tells a complete document from one that ends early, as a file
/// does while Claude Code writes it.
struct OAuthAccountScanner {
    private static let key = Array("oauthAccount".utf8)
    /// Strings longer than this are never the key, so their bytes are not kept.
    private static let maximumKeyLength = 64
    /// A larger `oauthAccount` object is not a login record.
    static let maximumObjectBytes = 1 << 20

    /// The bytes of the `oauthAccount` object, once it is complete.
    private(set) var object: Data?
    /// The root object ended.
    private(set) var isComplete = false
    /// The bytes cannot be one JSON object, however the file continues.
    private(set) var isMalformed = false

    private var depth = 0
    private var hasRoot = false
    private var isInString = false
    private var isEscaped = false
    private var text: [UInt8] = []
    private var isTextTooLong = false
    /// The last string that ended in the root object: a key, or a string value.
    private var lastString: [UInt8]?
    /// The key of the root-object member being read.
    private var memberKey: [UInt8]?
    private var capture: [UInt8]?

    /// More bytes cannot change the result.
    var isFinished: Bool { object != nil || isComplete || isMalformed }

    mutating func feed(_ bytes: Data) {
        for byte in bytes {
            guard !isFinished else { return }
            consume(byte)
        }
    }

    private mutating func consume(_ byte: UInt8) {
        if capture != nil {
            capture?.append(byte)
            if (capture?.count ?? 0) > Self.maximumObjectBytes {
                isMalformed = true
                return
            }
        }
        if isInString {
            consumeString(byte)
            return
        }
        switch byte {
        case UInt8(ascii: "\""):
            if depth == 0 { isMalformed = true }
            isInString = true
            text.removeAll(keepingCapacity: true)
            isTextTooLong = false
        case UInt8(ascii: ":"):
            if depth == 1 { memberKey = lastString }
        case UInt8(ascii: ","):
            if depth == 1 {
                memberKey = nil
                lastString = nil
            }
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            if depth == 0 {
                guard byte == UInt8(ascii: "{"), !hasRoot else {
                    isMalformed = true
                    return
                }
                hasRoot = true
            } else if depth == 1, byte == UInt8(ascii: "{"), memberKey == Self.key,
                capture == nil
            {
                capture = [byte]
            }
            depth += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            depth -= 1
            if depth < 0 {
                isMalformed = true
                return
            }
            if depth == 1, let captured = capture {
                object = Data(captured)
                capture = nil
            }
            if depth == 0 { isComplete = true }
        case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
            break
        default:
            // Numbers and literals are fine inside the root object, never outside it.
            if depth == 0 { isMalformed = true }
        }
    }

    private mutating func consumeString(_ byte: UInt8) {
        if isEscaped {
            isEscaped = false
            record(byte)
            return
        }
        switch byte {
        case UInt8(ascii: "\\"):
            isEscaped = true
            record(byte)
        case UInt8(ascii: "\""):
            isInString = false
            if depth == 1 { lastString = isTextTooLong ? nil : text }
        default:
            record(byte)
        }
    }

    /// Keeps the bytes of short strings in the root object, where the key can be.
    private mutating func record(_ byte: UInt8) {
        guard depth == 1, !isTextTooLong else { return }
        guard text.count < Self.maximumKeyLength else {
            isTextTooLong = true
            return
        }
        text.append(byte)
    }
}
