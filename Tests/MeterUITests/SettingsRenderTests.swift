import Foundation
import MeterDomain
import SwiftUI
import Testing

@testable import MeterApp
@testable import MeterUI

/// Renders each Settings tab, the Data controls with sample folders, and Diagnostics.
@MainActor @Suite struct SettingsRenderTests {
    @Test func everyTab() {
        var settings = MeterApp.Settings.preview
        settings.cards.order = [.account(.codex, "/Users/me/.codex")]
        let model = AppModel.preview(settings: settings)
        for tab in SettingsTab.allCases {
            Snapshot.render("settings-\(tab.title.lowercased())") {
                SettingsView(model: model, navigation: SettingsNavigation(tab: tab))
            }
        }
    }

    @Test func dataControls() {
        let accounts = [
            ClaudeSettingsModel.Account(
                id: "claude", defaultName: "default", path: "/Users/me/.claude", isDefault: true,
                isEnabled: true, isRemovable: false, reportedPlan: "Max 20x", issue: nil),
            ClaudeSettingsModel.Account(
                id: "claude-work", defaultName: "work", path: "/Users/me/.claude-work",
                isDefault: false, isEnabled: true, isRemovable: true, reportedPlan: nil,
                issue: "Sign in to Claude Code in this folder."),
        ]
        let homes = [
            CodexSettingsModel.Home(
                id: "/Users/me/.codex", path: "/Users/me/.codex", defaultName: "Codex",
                isImplicit: true, status: .signedIn),
            CodexSettingsModel.Home(
                id: "/Users/me/work/.codex", path: "/Users/me/work/.codex", defaultName: ".codex",
                isImplicit: false, status: .signedOut),
        ]
        let actions = ClaudeConnectionView.Actions(
            connectAutomatically: {}, connectManually: { _, _, _ in true }, disconnect: {})
        let connected = ClaudeConnectionView.Snapshot(
            connection: .automatic, automaticStatus: .signedIn, manualStatus: .signedOut,
            message: "Connected.")
        let off = ClaudeConnectionView.Snapshot(
            connection: .off, automaticStatus: .unknown("The Keychain is locked."),
            manualStatus: nil)

        Snapshot.render("settings-data-sources") {
            SettingsPage(title: "Data sources", subtitle: "Sample folders.", spacing: 16) {
                DataSourceCard(
                    symbol: "key.fill", tint: Palette.Tile.gold, title: "Claude",
                    subtitle: DataSourceText.claudeSubtitle(
                        connection: .automatic, isEnabled: true),
                    isEnabled: .constant(true)
                ) {
                    ClaudeConnectionView(snapshot: connected, actions: actions)
                    CardDivider()
                    ClaudeAccountsList(
                        accounts: accounts, names: ["claude-work": "Work"],
                        planOverrides: ["claude-work": "Team"], rename: { _, _ in },
                        setEnabled: { _, _ in }, setPlan: { _, _ in }, remove: { _ in }, add: {})
                }
                DataSourceCard(
                    symbol: "sparkles", tint: Palette.Tile.lagoon, title: "Codex",
                    subtitle: DataSourceText.codexSubtitle, isEnabled: .constant(true)
                ) {
                    CodexHomesList(
                        homes: homes, names: [:], isLoading: false,
                        error: "That Codex home is already listed.", rename: { _, _ in },
                        remove: { _ in }, add: {})
                }
            }
            .frame(width: 580)
        }
        Snapshot.render("settings-claude-manual") {
            SettingsCard {
                ClaudeConnectionView(snapshot: off, actions: actions, startsWithForm: true)
            }
            .padding(24)
            .frame(width: 580)
        }
        Snapshot.render("settings-claude-off") {
            SettingsCard { ClaudeConnectionView(snapshot: off, actions: actions) }
                .padding(24)
                .frame(width: 580)
        }
    }

    @Test func diagnostics() {
        let report = DiagnosticsReport(sections: [
            .init(
                title: "App",
                facts: [
                    DiagnosticFact("Version", "4.0.0 (400)"), DiagnosticFact("macOS", "27.0"),
                    DiagnosticFact("Updates", "running"),
                ]),
            .init(
                title: "Readings",
                facts: [
                    DiagnosticFact("Claude", "current, 2 accounts, 2026-10-04T12:00:00Z"),
                    DiagnosticFact("Codex", "stale since 2026-10-04T11:00:00Z: Offline"),
                ]),
        ])
        Snapshot.render("settings-diagnostics") {
            DiagnosticsSheet(report: report) { report }
        }
    }
}
