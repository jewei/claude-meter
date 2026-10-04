import MeterApp
import SwiftUI

/// Settings > Data: one card per source.
///
/// Each card is a ``DataSourceCard`` with the source switch. Claude adds its connection and
/// config dirs, Codex its homes. To add controls for a source, put a section view in its
/// card's content; it shows below a divider while the source is on.
struct DataSettingsView: View {
    let model: AppModel

    var body: some View {
        @Bindable var store = model.settings
        let settings = store.settings
        SettingsPage(
            title: "Data sources", subtitle: "Connect your accounts. Keep your energy in view.",
            spacing: 16
        ) {
            DataSourceCard(
                symbol: "key.fill", tint: Palette.Tile.gold, title: "Claude",
                subtitle: DataSourceText.claudeSubtitle(
                    connection: settings.claude.connection, isEnabled: settings.claude.isEnabled),
                isEnabled: $store.settings.claude.isEnabled,
                showsContent: model.claudeSettings != nil
            ) {
                if let claude = model.claudeSettings {
                    ClaudeSourceSection(claude: claude, settings: settings.claude)
                }
            }
            DataSourceCard(
                symbol: "sparkles", tint: Palette.Tile.lagoon, title: "Codex",
                subtitle: DataSourceText.codexSubtitle, isEnabled: $store.settings.codex.isEnabled,
                showsContent: model.codexSettings != nil
            ) {
                if let codex = model.codexSettings {
                    CodexSourceSection(codex: codex, names: settings.codex.accountNames)
                }
            }
            DataSourceCard(
                symbol: "cursorarrow.rays", tint: Palette.Tile.teal, title: "Cursor",
                subtitle: DataSourceText.cursorSubtitle,
                isEnabled: $store.settings.cursor.isEnabled)
            DataSourceCard(
                symbol: "atom", tint: Palette.Tile.graphite, title: "Grok",
                subtitle: DataSourceText.grokSubtitle, isEnabled: $store.settings.grok.isEnabled)
        }
        .task { await reload() }
        .onChange(of: settings.claude.isEnabled) { Task { await model.claudeSettings?.reload() } }
        .onChange(of: settings.codex.isEnabled) { Task { await model.codexSettings?.reload() } }
    }

    private func reload() async {
        async let claude: Void? = model.claudeSettings?.reload()
        async let codex: Void? = model.codexSettings?.reload()
        _ = await (claude, codex)
    }
}
