import Foundation
import MeterDomain
import Testing

@Suite struct RedactorTests {
    @Test(arguments: [
        ("token sk-ant-oat01-abc_DEF-123 failed", "token [redacted] failed"),
        ("oidc-AbC.def~ghi/jk=0123456789AbCdEf", "[redacted]"),
        ("key sk-proj-abcdef0123456789 failed", "key [redacted] failed"),
        ("sk-abcdef0123456789abcdef", "[redacted]"),
        ("grok xai-abcdef0123456789 failed", "grok [redacted] failed"),
        (#"{"OPENAI_API_KEY": "sk-proj-abcdef0123456789"}"#, #"{"OPENAI_API_KEY": "[redacted]"}"#),
        (#"{"OPENAI_API_KEY":"short"}"#, #"{"OPENAI_API_KEY":"[redacted]"}"#),
        (
            #"body: {\"access_token\":\"opaqueSecret123\"}"#,
            #"body: {\"access_token\":\"[redacted]\"}"#
        ),
        (
            "https://x.example.com/cb?token=opaqueSecret123&state=1",
            "https://x.example.com/cb?token=[redacted]&state=1"
        ),
        ("callback?code=abc123", "callback?code=[redacted]"),
        (#"{"oauth_access_token": "abc"}"#, #"{"oauth_access_token": "[redacted]"}"#),
        (#"{"session_token": "abc"}"#, #"{"session_token": "[redacted]"}"#),
        ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "Authorization: Basic [redacted]"),
        ("authorization: Token abc123", "authorization: Token [redacted]"),
        ("sent Basic dXNlcjpwYXNz to the proxy", "sent Basic [redacted] to the proxy"),
        ("jwt eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl end", "jwt [redacted] end"),
        ("Authorization: Bearer abc.DEF-123", "Authorization: Bearer [redacted]"),
        ("Cookie: sessionKey=abc123; other=1", "Cookie: [redacted]"),
        ("sessionKey=abc123; other=1", "sessionKey=[redacted]; other=1"),
        ("Cookie: sso=abc123; sso-rw=def456\nnext line", "Cookie: [redacted]\nnext line"),
        ("sent sso=abc123 to the API", "sent sso=[redacted] to the API"),
        (
            #"body: {\"token\":\"opaqueSecret123\",\"name\":\"ok\"}"#,
            #"body: {\"token\":\"[redacted]\",\"name\":\"ok\"}"#
        ),
        (#"{"token": "a\"b", "name": "ok"}"#, #"{"token": "[redacted]", "name": "ok"}"#),
        (#"{"secret_key": "abc123"}"#, #"{"secret_key": "[redacted]"}"#),
        (#"{\"private_key\":\"abc123\"}"#, #"{\"private_key\":\"[redacted]\"}"#),
        ("aws_secret_access_key=abc123", "aws_secret_access_key=[redacted]"),
        (
            #"{"private_key": "-----BEGIN PRIVATE KEY-----\nMIIEvQ+/x\n-----END PRIVATE KEY-----\n"}"#,
            #"{"private_key": "[redacted]"}"#
        ),
        ("-----BEGIN RSA PRIVATE KEY-----\nMIIEvQ cut", "[redacted]"),
        (
            "refresh failed: token=opaqueSecret123 expired",
            "refresh failed: token=[redacted] expired"
        ),
        ("Missing bearer abc.DEF-123", "Missing bearer [redacted]"),
        ("/Users/Sharedfoo/x", "/Users/[redacted]/x"),
        ("WorkosCursorSessionToken=user%3A%3Atoken", "WorkosCursorSessionToken=[redacted]"),
        (
            #"{"access_token": "abc", "refreshToken":"def"}"#,
            #"{"access_token": "[redacted]", "refreshToken":"[redacted]"}"#
        ),
        ("api_key=secret&x=1", "api_key=[redacted]&x=1"),
        (#"{"key": "xai-123", "name": "ok"}"#, #"{"key": "[redacted]", "name": "ok"}"#),
        ("org 123e4567-e89b-12d3-a456-426614174000", "org [redacted]"),
        ("mail me@example.com now", "mail [redacted] now"),
        ("/Users/alice/.claude/settings.json", "/Users/[redacted]/.claude/settings.json"),
        ("Email: me\nOrganization: Acme", "Email: [redacted]\nOrganization: [redacted]"),
    ])
    func redacts(input: String, expected: String) {
        #expect(Redactor.redact(input) == expected)
    }

    @Test(arguments: [
        "Rate limited. Try again in 5m (HTTP 429).",
        "oidc-client failed",
        "sk-learn and the risk-management-framework-document",
        "xai-models list",
        "Basic authentication is not supported.",
        "The Basic plan has no API access.",
        "Use the session token from Settings, or sign in with an OAuth token.",
        "Missing bearer token",
        "The Bearer token expired. Sign in again.",
        "CLAUDE_CONFIG_DIR='/Users/Shared/claude' claude /login",
        "/Users/Shared",
        "tokens=5 and max tokens: 10",
        "Your password must change.",
        "https://example.com/usage?state=1&page=2#key",
        "The task-runner-configuration-file changed.",
        // An empty identity line keeps the next line (review R4-D-02).
        "Email:\nRate limited. Try again in 5m.",
        "Organization: \t\nCwd:",
        "",
    ])
    func leavesOrdinaryTextAlone(text: String) {
        #expect(Redactor.redact(text) == text)
    }

    @Test func issuesAreAlwaysRedacted() {
        #expect(UsageIssue("failed for me@example.com").message == "failed for [redacted]")
        #expect(ProviderError("Bearer abc").issue.message == "Bearer [redacted]")
    }

    @Test func signInReasonsAreAlwaysRedacted() {
        let error = "The Keychain is locked for me@example.com."
        #expect(SignInStatus.unknown(error) == .unknown(SignInStatus.Reason(error)))
        guard case .unknown(let reason) = SignInStatus.unknown(error) else {
            Issue.record("Expected an unknown status.")
            return
        }
        #expect(reason.text == "The Keychain is locked for [redacted].")
        #expect("\(reason)" == reason.text)
    }

    /// Runs that made rules backtrack before: 10 s for 16 KiB of letters (review R3-D), and
    /// then 1 s for a run of `eyJ` and 2.4 s for runs of 64 letters and `_` (review R3-D-01).
    private static let adversarialUnits = [
        "a", "aB3", "a_", "a@", "a.", "a-", "eyJ", "eyJ.", String(repeating: "a", count: 64) + "_",
        "Bearer ", #""key":""#, #"\"key\":\""#, "sk-", "/Users/", "Basic ", "password=\"",
        "Email: ", "-----BEGIN ",
    ]

    /// The CPU time of this thread, so other work on a busy machine does not count. The best
    /// of three runs, so one interruption does not count either.
    private static func cpuTime(_ text: String) -> UInt64 {
        (0..<3).map { _ in
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = Redactor.redact(text)
            return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
        }.min() ?? 0
    }

    /// Twice the text takes about twice the time, never four times, and 16 KiB stays far below
    /// the old seconds. Each shape needs about 1 to 30 ms for 16 KiB in a debug build.
    @Test(arguments: adversarialUnits)
    func longRunsRedactQuickly(unit: String) {
        _ = Redactor.redact("warm up \(unit)")
        let half = Self.cpuTime(String(repeating: unit, count: 8_192 / unit.utf16.count))
        let full = Self.cpuTime(String(repeating: unit, count: 16_384 / unit.utf16.count))
        #expect(full < 3 * half + 5_000_000, "8 KiB: \(half) ns, 16 KiB: \(full) ns")
        #expect(full < 300_000_000, "16 KiB: \(full) ns")
    }

    @Test func longTextIsCutWithoutAPartialSecret() {
        let words = String(repeating: "word ", count: Redactor.maximumLength / 5 - 2)
        let text = words + "sk-ant-" + String(repeating: "x", count: 50_000)
        let result = Redactor.redact(text)
        #expect(result.hasSuffix(" …"))
        #expect(!result.contains("sk-ant"))
        #expect(!result.contains("xxx"))
        #expect(result.utf16.count <= Redactor.maximumLength + 2)
        #expect(Redactor.redact(String(repeating: "x", count: 50_000)) == "…")
    }

    /// The cut counts UTF-16 code units: one letter with many combining marks is one character
    /// but many units, and it is cut too.
    @Test func theCutCountsCodeUnitsNotCharacters() {
        let marks = String(repeating: "\u{301}", count: 100_000)
        #expect(Redactor.redact("a" + marks) == "…")
        let result = Redactor.redact("word a" + marks)
        #expect(result == "word …")
        let long = Redactor.redact(String(repeating: "é ", count: 20_000))
        #expect(long.utf16.count <= Redactor.maximumLength + 2)
        #expect(long.hasSuffix(" …"))
    }

    /// The cut can remove the closing quote of a secret. The value then goes to the end of the
    /// cut text, and the ellipsis comes after the redaction.
    @Test(arguments: [#"{"secret": ""#, #"{"password": ""#, #"{\"token\":\""#])
    func aQuotedSecretThatTheCutEndedIsRedacted(prefix: String) {
        let words = String(repeating: "alpha bravo ", count: 2_000)
        let result = Redactor.redact(prefix + words)
        #expect(!result.contains("alpha"))
        #expect(!result.contains("bravo"))
        #expect(result.hasSuffix("[redacted] …"))
    }

    @Test(arguments: [
        (
            #"{"password": "correct horse battery staple"}"#,
            #"{"password": "[redacted]"}"#
        ),
        (
            #"{"client_secret": "two words", "name": "ok"}"#,
            #"{"client_secret": "[redacted]", "name": "ok"}"#
        ),
        (
            #"{\"password\":\"correct horse\",\"name\":\"ok\"}"#,
            #"{\"password\":\"[redacted]\",\"name\":\"ok\"}"#
        ),
        ("password='correct horse' next", "password='[redacted]' next"),
        (#"{"password": "a\"b c"}"#, #"{"password": "[redacted]"}"#),
        (#"{"password": ""}"#, #"{"password": ""}"#),
        (#"{"secret": "alpha bravo"}"#, #"{"secret": "[redacted]"}"#),
    ])
    func quotedSecretsAreRedactedToTheirClosingQuote(input: String, expected: String) {
        #expect(Redactor.redact(input) == expected)
    }

    /// The labeled rule has no left edge, so a prefix before the label stays as it is.
    @Test(arguments: [
        ("my_app_access_token=abc123", "my_app_access_token=[redacted]"),
        ("OPENAI_API_KEY=sk-x", "OPENAI_API_KEY=[redacted]"),
        ("aws-secret-access-key: abc", "aws-secret-access-key: [redacted]"),
        (
            "a_b_c_d_e_f_g_h_i_j_k_session_token=abc",
            "a_b_c_d_e_f_g_h_i_j_k_session_token=[redacted]"
        ),
        (
            String(repeating: "p", count: 100) + "_refresh_token=abc",
            String(repeating: "p", count: 100) + "_refresh_token=[redacted]"
        ),
        ("access_token_refresh_token=abc", "access_token_refresh_token=[redacted]"),
        ("x-refresh_secret=abc", "x-refresh_secret=[redacted]"),
        ("contact first.last+tag@example.co.uk", "contact [redacted]"),
        (String(repeating: "u", count: 80) + "@example.com", "[redacted]"),
    ])
    func prefixedKeysAndEmailsAreFound(input: String, expected: String) {
        #expect(Redactor.redact(input) == expected)
    }

    /// A JWT starts at the left edge of a run, so a word that only contains `eyJ` stays.
    @Test func aTokenStartsAtTheEdgeOfARun() {
        #expect(Redactor.redact("t=eyJhbGciOi.eyJzdWIiOi.c2ln end") == "t=[redacted] end")
        #expect(Redactor.redact(#"{"id":"eyJhbGciOi.eyJzdWIiOi.c2ln"}"#) == #"{"id":"[redacted]"}"#)
        #expect(Redactor.redact("keyJar.eyJ.x") == "keyJar.eyJ.x")
    }
}
