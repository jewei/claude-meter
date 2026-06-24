import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("ClaudeAI organization resolution")
struct ClaudeAIOrgTests {
    @Test func parsesOrganizationsAndSkipsBlankUUIDs() throws {
        let json = """
            [{"uuid":"","name":"Broken"},
             {"uuid":"11111111-1111-1111-1111-111111111111","name":"API Org","capabilities":["api"]},
             {"uuid":"22222222-2222-2222-2222-222222222222","name":"Personal","capabilities":["chat","claude_pro"]}]
            """
        let orgs = try ClaudeAIUsageClient.parseOrganizations(json.data(using: .utf8)!)
        #expect(orgs.count == 2)
        #expect(orgs.first?.name == "API Org")
    }

    @Test func selectsChatOrgOverFirst() throws {
        let json = """
            [{"uuid":"11111111-1111-1111-1111-111111111111","name":"API Org","capabilities":["api"]},
             {"uuid":"22222222-2222-2222-2222-222222222222","name":"Personal","capabilities":["chat","claude_max"]}]
            """
        let orgs = try ClaudeAIUsageClient.parseOrganizations(json.data(using: .utf8)!)
        let chosen = ClaudeAIUsageClient.selectOrganization(from: orgs)
        #expect(chosen?.uuid == "22222222-2222-2222-2222-222222222222")
    }

    @Test func fallsBackToFirstWhenNoChatCapability() {
        let orgs = [
            ClaudeAIUsageClient.Organization(uuid: "a", name: nil, capabilities: ["api"]),
            ClaudeAIUsageClient.Organization(uuid: "b", name: nil, capabilities: []),
        ]
        #expect(ClaudeAIUsageClient.selectOrganization(from: orgs)?.uuid == "a")
    }

    @Test func selectsNilForEmpty() {
        #expect(ClaudeAIUsageClient.selectOrganization(from: []) == nil)
    }
}
