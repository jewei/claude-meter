import Foundation
import MeterDomain
import MeterPlatform
import ProviderClaude
import Testing

@testable import MeterApp

@Suite struct LiveProvidersTests {
    @Test func claudeHistoryReadsOnlyFoldersWithACard() {
        let accounts = [
            ClaudeAccount(
                id: "claude", name: "default", directory: URL(fileURLWithPath: "/c"),
                isDefault: true, isEnabled: true),
            ClaudeAccount(
                id: "claude-work", name: "work", directory: URL(fileURLWithPath: "/w"),
                isDefault: false, isEnabled: true),
            ClaudeAccount(
                id: "claude-old", name: "old", directory: URL(fileURLWithPath: "/o"),
                isDefault: false, isEnabled: false),
        ]
        #expect(LiveProviders.claudeHistoryRoots(accounts, connection: .off).isEmpty)
        #expect(
            LiveProviders.claudeHistoryRoots(accounts, connection: .manual).map(\.account)
                == ["claude"])
        #expect(
            LiveProviders.claudeHistoryRoots(accounts, connection: .automatic).map(\.account)
                == ["claude", "claude-work"])
    }
}
