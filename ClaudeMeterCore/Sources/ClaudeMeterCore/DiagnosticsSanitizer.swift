import Foundation

/// Redacts sensitive identifiers from diagnostics text per SPECS §16.4.
public enum DiagnosticsSanitizer {
    private static let emailPattern = #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    private static let homePathPattern = #"/Users/[^/\s]+"#
    private static let labeledFieldPattern = #"(?mi)^(Session name|Organization|Cwd|Email|Session id):\s*.+$"#
    private static let uuidPattern =
        #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    private static let sessionKeyPattern = #"sk-ant-[A-Za-z0-9_-]+"#

    public static func sanitize(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: sessionKeyPattern,
            with: "[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: uuidPattern,
            with: "[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: emailPattern,
            with: "[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: homePathPattern,
            with: "/Users/[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: labeledFieldPattern,
            with: "$1: [redacted]",
            options: .regularExpression
        )
        return result
    }
}
