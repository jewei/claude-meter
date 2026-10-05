import Foundation
import MeterDomain
import MeterTestSupport

@testable import MeterApp

/// Builders for presentation tests. Times are relative to `Date.reference()`.
enum Fixture {
    static func window(
        _ kind: QuotaWindow.Kind, used: Double?, resetsIn seconds: TimeInterval? = .hours(2),
        id: String? = nil, title: String? = nil, isBinding: Bool = true
    ) -> QuotaWindow {
        let defaultTitle =
            switch kind {
            case .session: "Session"
            case .weekly: "Weekly"
            case .scoped: "Opus Weekly"
            case .billing: "Billing"
            }
        return QuotaWindow(
            id: id ?? kind.rawValue, title: title ?? defaultTitle, kind: kind, usedPercent: used,
            resetsAt: seconds.map { .reference($0) }, isBinding: isBinding)
    }

    static func account(
        _ id: AccountID, session: Double? = 20, weekly: Double? = 10,
        observedAt: Date? = .reference(), plan: String? = nil, issue: UsageIssue? = nil,
        extra: [QuotaWindow] = [], balances: [Balance] = [], resets: ResetAllowance? = nil
    ) -> AccountUsage {
        AccountUsage(
            id: id, name: id.rawValue, plan: plan,
            windows: [window(.session, used: session), window(.weekly, used: weekly)] + extra,
            balances: balances, resetAllowance: resets, observedAt: observedAt, issue: issue)
    }

    static func usage(_ provider: ProviderID, _ accounts: AccountUsage...) -> ProviderUsage {
        ProviderUsage(provider: provider, accounts: accounts)
    }

    static func current(_ usage: ProviderUsage) -> Reading<ProviderUsage> {
        .current(usage, observedAt: usage.observedAt ?? .reference())
    }

    static func settings(
        enabled: Set<ProviderID> = [.claude], main: ProviderID = .claude,
        configure: (inout Settings) -> Void = { _ in }
    ) -> Settings {
        var settings = Settings()
        settings.hasCompletedOnboarding = true
        settings.claude.isEnabled = enabled.contains(.claude)
        settings.claude.connection = .automatic
        settings.codex.isEnabled = enabled.contains(.codex)
        settings.cursor.isEnabled = enabled.contains(.cursor)
        settings.grok.isEnabled = enabled.contains(.grok)
        settings.menuBar.provider = main
        configure(&settings)
        return settings
    }

    static func context(
        _ settings: Settings, readings: [ProviderID: Reading<ProviderUsage>],
        refreshing: Set<ProviderID> = [], restored: Set<ProviderID> = [],
        now: Date = .reference()
    ) -> PresentationContext {
        PresentationContext(
            settings: settings, readings: readings, refreshing: refreshing, restored: restored,
            now: now, calendar: .fixed())
    }
}
