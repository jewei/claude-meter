import Foundation
import MeterDomain
import MeterPlatform
import ProviderCodex
import ProviderCursor
import ProviderGrok

/// Every live provider, built once. This is the only file that names concrete provider types.
@MainActor
struct LiveProviders {
    let codex: CodexProvider
    let cursor: CursorProvider
    let grok: GrokProvider
    let cursorHistory: CursorTokenHistory

    init(settings: SettingsStore) {
        codex = CodexProvider(configuration: { @MainActor in settings.codexConfiguration })
        cursor = CursorProvider()
        grok = GrokProvider()
        cursorHistory = CursorTokenHistory()
    }

    var usageProviders: [any UsageProvider] {
        [codex, cursor, grok]
    }

    var historyProviders: [any TokenHistoryProvider] {
        [cursorHistory]
    }

    /// Providers that describe themselves in Diagnostics, in provider order.
    var diagnostics: [(ProviderID, any DiagnosticsReporting)] {
        [(.codex, codex), (.cursor, cursor), (.grok, grok)]
    }
}

extension SettingsStore {
    var codexConfiguration: CodexConfiguration {
        CodexConfiguration(
            extraHomes: settings.codex.extraHomes.map { URL(fileURLWithPath: $0) })
    }
}
