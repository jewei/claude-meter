import Testing
@testable import ClaudeMeterCore

@Suite("DiagnosticsSanitizer")
struct DiagnosticsSanitizerTests {
    @Test func redactsEmail() {
        let input = "Contact user@example.com for help"
        #expect(DiagnosticsSanitizer.sanitize(input).contains("[redacted]"))
        #expect(!DiagnosticsSanitizer.sanitize(input).contains("user@example.com"))
    }

    @Test func redactsHomePath() {
        let input = "Read from /Users/alice/.claude/stats-cache.json"
        let out = DiagnosticsSanitizer.sanitize(input)
        #expect(out.contains("/Users/[redacted]"))
        #expect(!out.contains("/Users/alice"))
    }

    @Test func redactsUUID() {
        let uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        let input = "GET /api/organizations/\(uuid)/usage"
        let out = DiagnosticsSanitizer.sanitize(input)
        #expect(!out.contains(uuid))
        #expect(out.contains("[redacted]"))
    }

    @Test func redactsSessionKey() {
        let key = "sk-ant-sid02-abcdefghijklmnopqrstuvwxyz"
        let out = DiagnosticsSanitizer.sanitize("Cookie sessionKey=\(key)")
        #expect(!out.contains(key))
        #expect(out.contains("[redacted]"))
    }
}

@Suite("CredentialValidator")
struct CredentialValidatorTests {
    @Test func acceptsValidOrgId() {
        let uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        #expect(CredentialValidator.isValidOrgId(uuid))
        #expect(CredentialValidator.normalizedOrgId(uuid) == uuid.lowercased())
    }

    @Test func rejectsInvalidOrgId() {
        #expect(!CredentialValidator.isValidOrgId("not-a-uuid"))
        #expect(!CredentialValidator.isValidOrgId(""))
    }

    @Test func acceptsValidSessionKey() {
        #expect(CredentialValidator.isValidSessionKey("sk-ant-sid02-abc123"))
    }

    @Test func rejectsSessionKeyWithInjectionCharacters() {
        #expect(!CredentialValidator.isValidSessionKey("sk-ant-sid02;evil=1"))
        #expect(!CredentialValidator.isValidSessionKey(""))
        #expect(!CredentialValidator.isValidSessionKey("not-a-key"))
    }
}

@Suite("ClaudeAIError")
struct ClaudeAIErrorTests {
    @Test func authFailureDetection() {
        #expect(ClaudeAIError.unauthorized.isAuthFailure)
        #expect(ClaudeAIError.httpError(401).isAuthFailure)
        #expect(ClaudeAIError.httpError(403).isAuthFailure)
        #expect(!ClaudeAIError.httpError(500).isAuthFailure)
        #expect(!ClaudeAIError.invalidURL.isAuthFailure)
    }
}
