import Foundation
import MeterDomain
import MeterPlatform
import ProviderClaude
import ProviderCodex
import ProviderCursor
import ProviderGrok

/// Every live provider, built once. This is the only file that names concrete provider types.
@MainActor
struct LiveProviders {
    let claude: ClaudeProvider
    let codex: CodexProvider
    let cursor: CursorProvider
    let grok: GrokProvider
    let claudeHistory: ClaudeTokenHistory
    let cursorHistory: CursorTokenHistory
    let codexHistory: CodexTokenHistory
    let grokHistory: GrokTokenHistory

    init(settings: SettingsStore, store: any KeyValueStore) {
        let claude = ClaudeProvider(
            configuration: { @MainActor in settings.claudeConfiguration }, store: store)
        self.claude = claude
        claudeHistory = ClaudeTokenHistory(roots: {
            let configuration = await MainActor.run { settings.claudeConfiguration }
            guard configuration.connection != .off else { return [] }
            return Self.claudeHistoryRoots(
                await claude.accounts(for: configuration), connection: configuration.connection)
        })
        let codex = CodexProvider(configuration: { @MainActor in settings.codexConfiguration })
        self.codex = codex
        cursor = CursorProvider()
        grok = GrokProvider()
        cursorHistory = CursorTokenHistory()
        // Each Codex home is one account's history root, the same homes that quota reads.
        // A slow disk throws instead of returning no homes, so the scan state survives.
        codexHistory = CodexTokenHistory(roots: {
            let configuration = await MainActor.run { settings.codexConfiguration }
            return try await codex.resolveHomes(for: configuration).map {
                HistoryRoot(account: $0.id, directory: $0.directory)
            }
        })
        let grokHome = GrokProvider.homeDirectory(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser)
        grokHistory = GrokTokenHistory(roots: {
            [HistoryRoot(account: .default, directory: grokHome)]
        })
    }

    /// The config dirs whose local sessions count as Claude token history: only folders that
    /// have a card. None before Claude is connected, only the default folder for a manual
    /// login (its one account), and every enabled folder in automatic mode.
    nonisolated static func claudeHistoryRoots(
        _ accounts: [ClaudeAccount], connection: ClaudeConfiguration.Connection
    ) -> [HistoryRoot] {
        let shown: [ClaudeAccount] =
            switch connection {
            case .off: []
            case .manual: accounts.filter { $0.id == ClaudeAccount.defaultID }
            case .automatic: accounts.filter(\.isEnabled)
            }
        return shown.map { HistoryRoot(account: $0.id, directory: $0.directory) }
    }

    var usageProviders: [any UsageProvider] {
        [claude, codex, cursor, grok]
    }

    var historyProviders: [any TokenHistoryProvider] {
        [claudeHistory, codexHistory, cursorHistory, grokHistory]
    }

    /// Providers that describe themselves in Diagnostics, in provider order.
    var diagnostics: [(ProviderID, any DiagnosticsReporting)] {
        [(.claude, claude), (.codex, codex), (.cursor, cursor), (.grok, grok)]
    }
}

extension SettingsStore {
    var codexConfiguration: CodexConfiguration {
        CodexConfiguration(
            extraHomes: settings.codex.extraHomes.map { URL(fileURLWithPath: $0) })
    }
}
