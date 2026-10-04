import MeterApp
import MeterDomain
import SwiftUI
import Testing

@testable import MeterUI

/// Renders the popover for the preview model in each main state.
@MainActor @Suite struct PopoverRenderTests {
    private func popover(_ model: AppModel) -> some View {
        let presentation = PopoverPresentation()
        presentation.isVisible = true
        return PopoverView(model: model, presentation: presentation)
    }

    @Test func accountsWithRings() {
        Snapshot.render("popover-rings", background: .clear) { popover(.preview()) }
    }

    @Test func accountsWithBars() {
        var settings = MeterApp.Settings.preview
        settings.appearance.cardStyle = .bars
        Snapshot.render("popover-bars", background: .clear) {
            popover(.preview(settings: settings))
        }
    }

    @Test func expandedBarCards() {
        var settings = MeterApp.Settings.preview
        settings.appearance.cardStyle = .bars
        settings.cards.expanded = [
            .account(.claude, "claude-work"), .account(.cursor, .default),
            .account(.codex, "/Users/me/.codex"),
        ]
        Snapshot.render("popover-bars-expanded", background: .clear) {
            popover(.preview(settings: settings))
        }
    }

    @Test func usedMode() {
        var settings = MeterApp.Settings.preview
        settings.appearance.meterMode = .used
        Snapshot.render("popover-used", background: .clear) {
            popover(.preview(settings: settings))
        }
    }

    @Test func statusScreens() {
        var welcome = MeterApp.Settings.preview
        welcome.hasCompletedOnboarding = false
        Snapshot.render("popover-welcome", background: .clear) {
            popover(.preview(settings: welcome))
        }

        var paused = MeterApp.Settings.preview
        paused.isPaused = true
        Snapshot.render("popover-paused", background: .clear) {
            popover(.preview(settings: paused, readings: []))
        }

        var none = MeterApp.Settings.preview
        none.claude.isEnabled = false
        none.codex.isEnabled = false
        none.cursor.isEnabled = false
        Snapshot.render("popover-no-sources", background: .clear) {
            popover(.preview(settings: none, readings: []))
        }

        var codexOnly = MeterApp.Settings.preview
        codexOnly.claude.isEnabled = false
        codexOnly.cursor.isEnabled = false
        Snapshot.render("popover-setup", background: .clear) {
            popover(.preview(settings: codexOnly, readings: []))
        }
    }

    @Test func noticesExtraUsageAndAStaleOtherProvider() {
        let now = Date()
        func window(_ kind: QuotaWindow.Kind, used: Double, hours: Double) -> QuotaWindow {
            QuotaWindow(
                id: kind.rawValue, title: kind == .session ? "Session" : "Weekly", kind: kind,
                usedPercent: used, resetsAt: now.addingTimeInterval(hours * 3_600),
                isBinding: true)
        }
        let main = AccountUsage(
            id: "claude", name: "default", plan: "Max 5x",
            windows: [
                window(.session, used: 97, hours: 0.5), window(.weekly, used: 64, hours: 40),
                QuotaWindow(
                    id: "extra-usage", title: "Extra usage", kind: .billing, usedPercent: 25,
                    resetsAt: nil, isBinding: false),
            ],
            balances: [
                Balance(kind: .extraUsage, amount: 12.5, limit: 50, unit: .currency("USD"))
            ],
            observedAt: now.addingTimeInterval(-30), sharesLogin: true)
        let work = AccountUsage(
            id: "claude-work", name: "work", plan: nil, windows: [], observedAt: nil,
            issue: UsageIssue("Sign in to Claude Code in this folder.", needsAction: true))
        let codex = AccountUsage(
            id: "/Users/me/.codex", name: "codex", plan: "pro",
            windows: [window(.weekly, used: 100, hours: 20)],
            observedAt: now.addingTimeInterval(-3_600))
        let readings = [
            ProviderUsage(provider: .claude, accounts: [main, work]),
            ProviderUsage(provider: .codex, accounts: [codex]),
        ]
        var settings = MeterApp.Settings.preview
        settings.cursor.isEnabled = false
        Snapshot.render("popover-notices", background: .clear) {
            popover(.preview(settings: settings, readings: readings))
        }
    }

    @Test func staleMainMeter() {
        let stale = AccountUsage(
            id: "claude", name: "default", plan: "Pro",
            windows: [
                QuotaWindow(
                    id: "session", title: "Session", kind: .session, usedPercent: 40,
                    resetsAt: Date().addingTimeInterval(7_200), isBinding: true)
            ],
            observedAt: Date().addingTimeInterval(-4_000))
        var settings = MeterApp.Settings.preview
        settings.codex.isEnabled = false
        settings.cursor.isEnabled = false
        Snapshot.render("popover-stale", background: .clear) {
            popover(
                .preview(
                    settings: settings,
                    readings: [ProviderUsage(provider: .claude, accounts: [stale])]))
        }
    }

    @Test func loading() {
        Snapshot.render("popover-loading") {
            LoadingView(message: "Checking your tanks…").frame(width: PanelLayout.width)
        }
    }
}
