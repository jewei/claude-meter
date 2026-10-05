import Foundation
import MeterDomain
import MeterPlatform

extension AppModel {
    /// A model with fixed readings and no providers, for SwiftUI previews and UI tests.
    public static func preview(
        settings: Settings = .preview, readings: [ProviderUsage] = PreviewData.readings
    ) -> AppModel {
        let store = MemoryStore()
        store.set(SettingsCodec.encode(settings), forKey: SettingsStore.storageKey)
        let usage = UsageStore(providers: [])
        usage.restore(
            Dictionary(readings.map { ($0.provider, $0) }, uniquingKeysWith: { a, _ in a }))
        return AppModel(
            settings: SettingsStore(store: store), usage: usage, scheduler: nil,
            updater: DisabledUpdater(), logFile: .temporary())
    }
}

extension Settings {
    /// Onboarded, Claude and Codex on, energy-left rings.
    public static var preview: Settings {
        var settings = Settings()
        settings.hasCompletedOnboarding = true
        settings.claude.connection = .automatic
        settings.codex.isEnabled = true
        settings.cursor.isEnabled = true
        return settings
    }
}

/// Synthetic readings for previews and UI tests. Times are relative to now.
public enum PreviewData {
    public static var readings: [ProviderUsage] {
        let now = Date()
        func window(
            _ kind: QuotaWindow.Kind, _ title: String, used: Double, hours: Double,
            id: String? = nil, binding: Bool = true
        ) -> QuotaWindow {
            QuotaWindow(
                id: id ?? kind.rawValue, title: title, kind: kind, usedPercent: used,
                resetsAt: now.addingTimeInterval(hours * 3_600), isBinding: binding)
        }
        let work = AccountUsage(
            id: "claude-work", name: "work", plan: "Max 20x",
            windows: [
                window(.session, "Session", used: 22, hours: 3.2),
                window(.weekly, "Weekly", used: 36, hours: 151),
                window(.scoped, "Opus Weekly", used: 48, hours: 151, id: "seven_day_opus"),
            ],
            resetAllowance: ResetAllowance(
                available: 1,
                resets: [
                    .init(title: "Usage limit reset", expiresAt: now.addingTimeInterval(86_400 * 5))
                ]),
            observedAt: now.addingTimeInterval(-90))
        let personal = AccountUsage(
            id: "claude", name: "default", plan: "Pro",
            windows: [
                window(.session, "Session", used: 81, hours: 1.1),
                window(.weekly, "Weekly", used: 64, hours: 40),
            ],
            observedAt: now.addingTimeInterval(-90))
        let codex = AccountUsage(
            id: "/Users/me/.codex", name: "codex", plan: "plus",
            windows: [
                window(.session, "Session", used: 12, hours: 4),
                window(.weekly, "Weekly", used: 30, hours: 90),
            ],
            balances: [Balance(kind: .credits, amount: 12, unit: .credits)],
            observedAt: now.addingTimeInterval(-120))
        let cursor = AccountUsage(
            id: .default, name: "Cursor", plan: "Pro",
            windows: [
                window(.billing, "Total", used: 42, hours: 300),
                window(.scoped, "Auto", used: 30, hours: 300, id: "auto", binding: false),
                window(.scoped, "API", used: 12, hours: 300, id: "api", binding: false),
            ],
            balances: [Balance(kind: .spend, amount: 120.25, limit: 400, unit: .currency("USD"))],
            observedAt: now.addingTimeInterval(-60))
        return [
            ProviderUsage(provider: .claude, accounts: [work, personal]),
            ProviderUsage(provider: .codex, accounts: [codex]),
            ProviderUsage(provider: .cursor, accounts: [cursor]),
        ]
    }
}
