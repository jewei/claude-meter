import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Codex credential ownership")
struct CodexCredentialIdentityTests {
    private func auth(member: String, workspace: String, token: String) throws -> Data {
        let claims: [String: Any] = [
            "sub": member,
            "https://api.openai.com/auth": ["chatgpt_account_id": workspace],
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: [
            "tokens": ["access_token": token, "id_token": "header.\(payload).signature"]
        ])
    }

    @Test func tokenRotationPreservesOwner() throws {
        let first = CodexOAuthCredentialsStore.identity(
            data: try auth(member: "member-a", workspace: "workspace-a", token: "old"))
        let rotated = CodexOAuthCredentialsStore.identity(
            data: try auth(member: "member-a", workspace: "workspace-a", token: "new"))
        #expect(first.ownerID?.count == 64)
        #expect(first.ownerID == rotated.ownerID)
        #expect(first.acceptsResult(after: rotated))
        #expect(first != rotated)
    }

    @Test func bothMemberAndWorkspaceIdentifyTheOwner() throws {
        let original = CodexOAuthCredentialsStore.identity(
            data: try auth(member: "member-a", workspace: "workspace-a", token: "old"))
        for (member, workspace) in [("member-b", "workspace-a"), ("member-a", "workspace-b")] {
            let changed = CodexOAuthCredentialsStore.identity(
                data: try auth(member: member, workspace: workspace, token: "new"))
            #expect(original.ownerID != changed.ownerID)
            #expect(!original.acceptsResult(after: changed))
        }
        #expect(!original.acceptsResult(after: .unavailable))
    }

    @Test func unknownClaimsAllowOnlyAnUnchangedSource() {
        let original = CodexOAuthCredentialsStore.identity(
            data: Data(#"{"tokens":{"access_token":"first"}}"#.utf8))
        let changed = CodexOAuthCredentialsStore.identity(
            data: Data(#"{"tokens":{"access_token":"second"}}"#.utf8))
        #expect(original.ownerID == nil)
        #expect(original.acceptsResult(after: original))
        #expect(!original.acceptsResult(after: changed))
        #expect(!CodexCredentialIdentity.unavailable.acceptsResult(after: .unavailable))
    }

    @Test func missingAndMalformedFilesHaveNoDurableOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = CodexOAuthCredentialsStore.identity(codexHome: directory)
        #expect(missing.ownerID == nil)
        #expect(missing.acceptsResult(after: missing))
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("auth.json"))
        let invalid = CodexOAuthCredentialsStore.identity(codexHome: directory)
        #expect(invalid.ownerID == nil)
        #expect(!missing.acceptsResult(after: invalid))
    }
}
