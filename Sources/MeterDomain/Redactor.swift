import Foundation

/// Removes secrets and personal data from text before it reaches the UI, a log, or the disk.
///
/// Every error message and log line passes through ``redact(_:)``. The rules run in order, and
/// earlier rules handle the more specific token formats.
public enum Redactor {
    public static let placeholder = "[redacted]"

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.expression.stringByReplacingMatches(
                in: result, range: range, withTemplate: rule.template)
        }
        return result
    }

    private struct Rule {
        let expression: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String = Redactor.placeholder) {
            // The patterns are literals covered by tests, so a failure is a programming error.
            expression = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }
    }

    private static let rules: [Rule] = [
        // PEM private keys, also inside JSON, where line breaks are `\n`.
        Rule(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#),
        // Anthropic API and OAuth tokens.
        Rule(#"sk-ant-[A-Za-z0-9_-]+"#),
        // OpenAI API keys, such as `sk-proj-…`. The length keeps words like `sk-learn`.
        Rule(#"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{16,}"#),
        // xAI API keys.
        Rule(#"\bxai-[A-Za-z0-9_-]{16,}"#),
        // Grok OIDC tokens. The length keeps words like `oidc-client`.
        Rule(#"\boidc-[A-Za-z0-9._~+/=-]{20,}"#),
        // JSON Web Tokens.
        Rule(#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#),
        // Authorization header values. Words that name the scheme, as in "Missing bearer
        // token", are not values.
        Rule(
            #"(?i)\b(Bearer)\s+(?!(?:tokens?|auth|authentication|authorization|header|scheme|credentials?)\b)[A-Za-z0-9._~+/\-=]+"#,
            "$1 \(placeholder)"),
        Rule(#"(?i)\b(Authorization:\s*[A-Za-z]+)\s+[^\s,;]+"#, "$1 \(placeholder)"),
        // Basic credentials outside a header: Base64 with a digit, a symbol, or a lowercase
        // letter followed by an uppercase one, so `Basic authentication` stays.
        Rule(
            #"\b((?i:basic))\s+(?=[A-Za-z0-9+/]*(?:[0-9+/]|[a-z][A-Z]))[A-Za-z0-9+/]{8,}={0,2}(?![A-Za-z0-9+/=])"#,
            "$1 \(placeholder)"),
        // Session cookies, and every value of a cookie header.
        Rule(
            #"(?i)\b(sessionKey=|WorkosCursorSessionToken=|sso(?:-rw)?=)[^;\s]+"#,
            "$1\(placeholder)"),
        Rule(#"(?i)\b(Cookie:[ \t]*)[^\r\n]+"#, "$1\(placeholder)"),
        // Labeled secrets in JSON, escaped JSON, query strings, or prose, with any prefix:
        // `"access_token": "…"`, `{\"session_token\":\"…\"}`, `OPENAI_API_KEY=…`,
        // `"secret_key": "…"`.
        Rule(
            #"(?i)((?:[A-Za-z0-9]+[_-])*(?:access|refresh|id|session|auth)[_-]?token|(?:[A-Za-z0-9]+[_-])*(?:api|secret|private|access)[_-]?key|client[_-]?secret|password)(\\?["']?\s*[:=]\s*\\?["']?)[^"'\\,\s;}&]+"#,
            "$1$2\(placeholder)"),
        // Secrets in URL query parameters: `?token=…`, `&code=…`.
        Rule(
            #"(?i)([?&](?:token|key|code|secret|signature|access_token)=)[^&\s#"']+"#,
            "$1\(placeholder)"),
        // Tokens and secrets assigned in prose: `token=…`, `refresh_secret=…`.
        Rule(#"(?i)\b((?:[A-Za-z0-9]+[_-])*(?:token|secret))=[^\s&"',;]+"#, "$1=\(placeholder)"),
        // Generic secret fields in JSON and in escaped JSON: `"key": "…"`, `\"token\":\"…\"`.
        Rule(#"(?i)"(key|token|secret)"(\s*:\s*)"(?:[^"\\]|\\.)*""#, "\"$1\"$2\"\(placeholder)\""),
        Rule(
            #"(?i)\\"(key|token|secret)\\"(\s*:\s*)\\"(?:[^"\\]|\\[^"])*\\""#,
            #"\\"$1\\"$2\\"\#(placeholder)\\""#),
        // UUIDs identify accounts and organizations.
        Rule(#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#),
        // Email addresses.
        Rule(#"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        // Home directories reveal the macOS user name. `/Users/Shared` is no user, and a
        // command shown on a card must keep a path in it.
        Rule(#"/Users/(?!Shared(?![^/\s"']))[^/\s"']+"#, "/Users/\(placeholder)"),
        // Identity lines printed by command-line tools.
        Rule(
            #"(?mi)^(Session name|Organization|Cwd|Email|Session id):\s*.+$"#, "$1: \(placeholder)"),
    ]
}
