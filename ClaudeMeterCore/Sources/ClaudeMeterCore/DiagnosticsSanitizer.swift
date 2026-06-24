import Foundation

/// Redacts sensitive identifiers from diagnostics text per SPECS §16.4.
public enum DiagnosticsSanitizer {
    private static let emailPattern = #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    private static let homePathPattern = #"/Users/[^/\s]+"#
    private static let labeledFieldPattern =
        #"(?mi)^(Session name|Organization|Cwd|Email|Session id):\s*.+$"#
    private static let uuidPattern =
        #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    private static let sessionKeyPattern = #"sk-ant-[A-Za-z0-9_-]+"#
    private static let oidcTokenPattern = #"oidc-[A-Za-z0-9._~+/\-=]+"#
    /// JWTs (e.g. Cursor access/refresh tokens): three base64url segments.
    private static let jwtPattern = #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#
    private static let bearerTokenPattern = #"(?i)(Bearer)\s+[A-Za-z0-9._~+/\-=]+"#
    private static let sessionCookiePattern = #"(?i)(sessionKey=)[^;\s]+"#
    private static let labeledTokenPattern =
        #"(?i)\b(access[_-]?token|accessToken|refresh[_-]?token|refreshToken)(["']?\s*[:=]\s*["']?)[^"',\s;}]+(["']?)"#

    public static func sanitize(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: sessionKeyPattern,
            with: "[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: oidcTokenPattern,
            with: "[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: jwtPattern,
            with: "[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: bearerTokenPattern,
            with: "$1 [redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: sessionCookiePattern,
            with: "$1[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: labeledTokenPattern,
            with: "$1$2[redacted]$3",
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
