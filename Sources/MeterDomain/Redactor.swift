import Foundation

/// Removes secrets and personal data from text before it reaches the UI, a log, or the disk.
///
/// Every error message and log line passes through ``redact(_:)``. The rules run in order, and
/// earlier rules handle the more specific token formats.
///
/// Every rule is linear in the length of the text. A rule starts at a fixed word, or only at
/// the left edge of a run (a lookbehind), so a long run is not scanned again from each of its
/// positions. A repeated part that can fail after it has a bound, or is possessive (`++`) so
/// the expression cannot backtrack into it. `RedactorTests.longRunsRedactQuickly` measures
/// this for the shapes that broke it before.
public enum Redactor {
    public static let placeholder = "[redacted]"

    /// Longer text, in UTF-16 code units (the units of the regular expressions), is cut first,
    /// so a redaction always ends quickly. The UI, a log line, and Diagnostics never need more.
    public static let maximumLength = 16_384

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let (head, isCut) = cut(text)
        var result = head
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.expression.stringByReplacingMatches(
                in: result, range: range, withTemplate: rule.template)
        }
        // The rules see the end of the cut text as the end of the text, so a quoted secret
        // that lost its closing quote is still found. The ellipsis comes after them.
        guard isCut else { return result }
        return result.isEmpty ? "…" : result + " …"
    }

    /// At most ``maximumLength`` UTF-16 code units, without the last word, which the cut can
    /// split so that no rule finds it. The count is of code units, not of characters: one
    /// letter with a million combining marks is one character.
    private static func cut(_ text: String) -> (head: String, isCut: Bool) {
        // A UTF-8 count is fast, and it is never smaller than the UTF-16 count.
        guard text.utf8.count > maximumLength else { return (text, false) }
        let scalars = text.unicodeScalars
        var units = 0
        var lastSpace: String.UnicodeScalarView.Index?
        for index in scalars.indices {
            let scalar = scalars[index]
            units += scalar.utf16.count
            if units > maximumLength {
                return (lastSpace.map { String(scalars[..<$0]) } ?? "", true)
            }
            if scalar.properties.isWhitespace { lastSpace = index }
        }
        return (text, false)
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

    // Why each rule is linear is in its comment. "Ends the match" means that once the fixed
    // start matched, the run always succeeds, so the search goes on after it.
    private static let rules: [Rule] = [
        // PEM private keys, also inside JSON, where line breaks are `\n`. A key that the cut
        // ended runs to the end of the text. Starts at a fixed word; the key type has a bound,
        // and the lazy body always ends the match.
        Rule(
            #"-----BEGIN [A-Z ]{0,32}PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]{0,32}PRIVATE KEY-----|$)"#
        ),
        // Anthropic API and OAuth tokens. The run ends the match.
        Rule(#"sk-ant-[A-Za-z0-9_-]+"#),
        // OpenAI API keys, such as `sk-proj-…`. The length keeps words like `sk-learn`. A run
        // of 16 or more ends the match; a shorter one fails within 16 characters.
        Rule(#"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{16,}"#),
        // xAI API keys.
        Rule(#"\bxai-[A-Za-z0-9_-]{16,}"#),
        // Grok OIDC tokens. The length keeps words like `oidc-client`.
        Rule(#"\boidc-[A-Za-z0-9._~+/=-]{20,}"#),
        // JSON Web Tokens. Starts only at the left edge of a run, and the first two segments
        // are possessive, so a run of `eyJ` is scanned once, not once from each `eyJ`.
        Rule(#"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]++\.[A-Za-z0-9_-]++\.[A-Za-z0-9_-]+"#),
        // Authorization header values. Words that name the scheme, as in "Missing bearer
        // token", are not values. Starts at a fixed word; the spaces are possessive.
        Rule(
            #"(?i)\b(Bearer)\s++(?!(?:tokens?|auth|authentication|authorization|header|scheme|credentials?)\b)[A-Za-z0-9._~+/\-=]+"#,
            "$1 \(placeholder)"),
        Rule(#"(?i)\b(Authorization:\s*+[A-Za-z]++)\s++[^\s,;]+"#, "$1 \(placeholder)"),
        // Basic credentials outside a header: Base64 with a digit, a symbol, or a lowercase
        // letter followed by an uppercase one, so `Basic authentication` stays. Starts at a
        // fixed word followed by spaces, so each run has at most one start.
        Rule(
            #"\b((?i:basic))\s++(?=[A-Za-z0-9+/]*(?:[0-9+/]|[a-z][A-Z]))[A-Za-z0-9+/]{8,}+={0,2}+(?![A-Za-z0-9+/=])"#,
            "$1 \(placeholder)"),
        // Session cookies, and every value of a cookie header. The value ends the match.
        Rule(
            #"(?i)\b(sessionKey=|WorkosCursorSessionToken=|sso(?:-rw)?=)[^;\s]+"#,
            "$1\(placeholder)"),
        Rule(#"(?i)\b(Cookie:[ \t]*)[^\r\n]+"#, "$1\(placeholder)"),
        // Labeled secrets in JSON, escaped JSON, query strings, or prose, with any prefix:
        // `"access_token": "…"`, `{\"session_token\":\"…\"}`, `OPENAI_API_KEY=…`,
        // `"secret_key": "…"`. The rule has no left edge, so a prefix such as `OPENAI_` stays
        // in front of the match unchanged. A quoted value is taken to its closing quote, or to
        // the end of the text, so a value with spaces goes completely. Starts at a fixed word;
        // the spaces and the quoted value are possessive, and the value ends the match.
        Rule(
            #"(?i)((?:access|refresh|id|session|auth)[_-]?token|(?:api|secret|private|access)[_-]?key|client[_-]?secret|password)(\\?["']?\s*+[:=]\s*+)(?:(\\")(?:[^"\\]|\\[^"])++|(")(?:[^"\\]|\\.)++|(')(?:[^'\\]|\\.)++|[^"'\\,\s;}&]+)"#,
            "$1$2$3$4$5\(placeholder)"),
        // Secrets in URL query parameters: `?token=…`, `&code=…`. The value ends the match.
        Rule(
            #"(?i)([?&](?:token|key|code|secret|signature|access_token)=)[^&\s#"']+"#,
            "$1\(placeholder)"),
        // Tokens and secrets assigned in prose: `token=…`, `refresh_secret=…`. Starts at a
        // fixed word that no letter or digit comes before; the value ends the match.
        Rule(#"(?i)(?<![A-Za-z0-9])(token|secret)=[^\s&"',;]+"#, "$1=\(placeholder)"),
        // Generic secret fields in JSON and in escaped JSON: `"key": "…"`, `\"token\":\"…\"`.
        // The value goes to its closing quote, which stays, or to the end of the text. Starts
        // at a fixed word; the value is possessive and ends the match.
        Rule(#"(?i)"(key|token|secret)"(\s*+:\s*+)"(?:[^"\\]|\\.)*+"#, "\"$1\"$2\"\(placeholder)"),
        Rule(
            #"(?i)\\"(key|token|secret)\\"(\s*+:\s*+)\\"(?:[^"\\]|\\[^"])*+"#,
            #"\\"$1\\"$2\\"\#(placeholder)"#),
        // UUIDs identify accounts and organizations. Fixed length.
        Rule(#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#),
        // Email addresses. The local part starts only at the left edge of its run and is
        // possessive, so it goes completely, at any length; the domain has the bounds of
        // RFC 5321.
        Rule(#"(?<![A-Z0-9a-z._%+-])[A-Z0-9a-z._%+-]++@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,63}"#),
        // Home directories reveal the macOS user name. `/Users/Shared` is no user, and a
        // command shown on a card must keep a path in it. The name ends the match.
        Rule(#"/Users/(?!Shared(?![^/\s"']))[^/\s"']+"#, "/Users/\(placeholder)"),
        // Identity lines printed by command-line tools. Starts only at a line start. The spaces
        // after the label never include a line break, so an empty value keeps the next line;
        // they are possessive, so a value of only spaces stays as it is.
        Rule(
            #"(?mi)^(Session name|Organization|Cwd|Email|Session id):[ \t]*+.+$"#,
            "$1: \(placeholder)"),
    ]
}
