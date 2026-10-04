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
            #"{"private_key": "[redacted]\n"}"#
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

    /// A long run without separators took 10 s for 16 KiB when two rules backtracked over the
    /// whole text (review R3-D). Every rule is linear now; the limit leaves a wide margin.
    @Test(arguments: ["a", "aB3", "a_", "a@"])
    func longRunsRedactQuickly(unit: String) {
        let text = String(repeating: unit, count: Redactor.maximumLength / unit.count)
        let start = ContinuousClock.now
        _ = Redactor.redact(text)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func longTextIsCutWithoutAPartialSecret() {
        let words = String(repeating: "word ", count: Redactor.maximumLength / 5 - 2)
        let text = words + "sk-ant-" + String(repeating: "x", count: 50_000)
        let result = Redactor.redact(text)
        #expect(result.hasSuffix(" …"))
        #expect(!result.contains("sk-ant"))
        #expect(!result.contains("xxx"))
        #expect(result.count <= Redactor.maximumLength + 2)
        #expect(Redactor.redact(String(repeating: "x", count: 50_000)) == "…")
    }

    @Test func boundedRulesStillFindPrefixedKeysAndEmails() {
        #expect(Redactor.redact("my_app_access_token=abc123") == "my_app_access_token=[redacted]")
        #expect(Redactor.redact("contact first.last+tag@example.co.uk") == "contact [redacted]")
    }

}
