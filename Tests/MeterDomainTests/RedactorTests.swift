import MeterDomain
import Testing

@Suite struct RedactorTests {
    @Test(arguments: [
        ("token sk-ant-oat01-abc_DEF-123 failed", "token [redacted] failed"),
        ("oidc-AbC.def~ghi/jk=", "[redacted]"),
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

    @Test func leavesOrdinaryTextAlone() {
        let text = "Rate limited. Try again in 5m (HTTP 429)."
        #expect(Redactor.redact(text) == text)
        #expect(Redactor.redact("") == "")
    }

    @Test func issuesAreAlwaysRedacted() {
        #expect(UsageIssue("failed for me@example.com").message == "failed for [redacted]")
        #expect(ProviderError("Bearer abc").issue.message == "Bearer [redacted]")
    }
}
