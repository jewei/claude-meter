import Foundation
import MeterApp
import MeterDomain
import SwiftUI
import Testing

@testable import MeterUI

/// Renders the status item label in each state, as a strip of the menu bar.
@MainActor @Suite struct MenuBarRenderTests {
    private let now = Date()

    private func account(session: Double, weekly: Double = 30, age: TimeInterval = 60)
        -> AccountUsage
    {
        AccountUsage(
            id: "claude", name: "default", plan: "Pro",
            windows: [
                QuotaWindow(
                    id: "session", title: "Session", kind: .session, usedPercent: session,
                    resetsAt: now.addingTimeInterval(3_600), isBinding: true),
                QuotaWindow(
                    id: "weekly", title: "Weekly", kind: .weekly, usedPercent: weekly,
                    resetsAt: now.addingTimeInterval(86_400), isBinding: true),
            ],
            observedAt: now.addingTimeInterval(-age))
    }

    private func model(
        _ account: AccountUsage?, refreshing: Set<ProviderID> = [],
        failed: Bool = false, configure: (inout MeterApp.Settings) -> Void = { _ in }
    ) -> MenuBarModel {
        var settings = MeterApp.Settings.preview
        configure(&settings)
        var readings: [ProviderID: Reading<ProviderUsage>] = [:]
        if let account {
            let usage = ProviderUsage(provider: .claude, accounts: [account])
            readings[.claude] = .current(usage, observedAt: now)
        } else if failed {
            readings[.claude] = .failed(UsageIssue("Sign in to Claude Code."))
        }
        return MenuBarModel(
            PresentationContext(
                settings: settings, readings: readings, refreshing: refreshing, now: now))
    }

    @Test func everyState() {
        let states: [(String, MenuBarModel, Date?)] = [
            ("full", model(account(session: 20)), nil),
            ("low", model(account(session: 85)), nil),
            ("critical", model(account(session: 97)), nil),
            ("critical-pulse-peak", model(account(session: 97)), now.addingTimeInterval(-0.6)),
            ("tapped-out", model(account(session: 100)), nil),
            ("stale", model(account(session: 20, age: 3_600)), nil),
            ("loading", model(nil, refreshing: [.claude]), nil),
            ("error", model(nil, failed: true), nil),
            ("paused", model(account(session: 20)) { $0.isPaused = true }, nil),
            (
                "both",
                model(account(session: 1, weekly: 27)) { $0.appearance.menuBarWindow = .both }, nil
            ),
            ("used", model(account(session: 20)) { $0.appearance.meterMode = .used }, nil),
        ]
        Snapshot.render("menubar", background: .clear) {
            MenuBarStrip(states: states)
        }
        #expect(states[0].1.text == "80% 5h")
        #expect(states[6].1.icon == .loading)
    }
}

/// Each label on a menu-bar colored strip, with its name.
private struct MenuBarStrip: View {
    let states: [(String, MenuBarModel, Date?)]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                HStack(spacing: 12) {
                    Text(state.0)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .trailing)
                    MenuBarLabel(model: state.1, pulseStartedAt: state.2)
                        .padding(.horizontal, 5)
                        .frame(height: 24)
                        .background(colorScheme == .dark ? Color(white: 0.17) : Color(white: 0.93))
                }
            }
        }
        .padding(12)
        .background(colorScheme == .dark ? Color(white: 0.1) : .white)
    }
}
