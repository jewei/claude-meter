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
        // Each enabled config dir is one account's history root.
        claudeHistory = ClaudeTokenHistory(roots: {
            let configuration = await MainActor.run { settings.claudeConfiguration }
            return await claude.accounts(for: configuration).filter(\.isEnabled).map {
                HistoryRoot(account: $0.id, directory: $0.directory)
            }
        })
        let codex = CodexProvider(configuration: { @MainActor in settings.codexConfiguration })
        self.codex = codex
        cursor = CursorProvider()
        grok = GrokProvider()
        cursorHistory = CursorTokenHistory()
        // Each Codex home is one account's history root, the same homes that quota reads.
        codexHistory = CodexTokenHistory(roots: {
            let configuration = await MainActor.run { settings.codexConfiguration }
            return await codex.homes(for: configuration).map {
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
