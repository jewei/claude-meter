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
        ("Cookie: sessionKey=abc123; other=1", "Cookie: sessionKey=[redacted]; other=1"),
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
}
