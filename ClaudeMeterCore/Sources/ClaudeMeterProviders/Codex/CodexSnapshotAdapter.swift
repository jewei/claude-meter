import ClaudeMeterCore
import Foundation

extension CodexUsage {
    /// The app supplies the existing canonical home key and user-chosen label.
    /// Credential ownership checks stay in the fetch/persistence path.
    public func providerAccountSnapshot(
        id: String, label: String, observedAt: Date? = nil, isStale: Bool = false
    ) -> ProviderAccountSnapshot {
        let windows = [primaryWindow, secondaryWindow].compactMap { $0 }.map { window in
            UsageWindow(
                id: window.kind.rawValue, title: window.displayLabel,
                kind: window.durationSeconds.map { $0 > 86_400 ? .weekly : .session }
                    ?? (window.kind == .secondary ? .weekly : .session),
                usedPercent: window.usedPercent, resetAt: window.resetAt)
        }
        var balances: [BalanceItem] = []
        if let credits = usageCredits {
            balances.append(
                BalanceItem(
                    id: "credits", title: "Credits",
                    value: credits.unlimited || !credits.remaining.isFinite
                        ? nil : Decimal(string: String(credits.remaining)),
                    unit: "credits", displayText: credits.unlimited ? "Unlimited" : nil))
        }
        if let resets = rateLimitResets {
            balances.append(
                BalanceItem(
                    id: "usage-resets", title: "Usage limit resets",
                    value: Decimal(resets.availableCount), unit: "resets",
                    details: resets.credits?.map {
                        let title = $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return BalanceDetail(
                            title: title.isEmpty ? "Usage reset" : title, expiresAt: $0.expiresAt)
                    }))
        }
        return ProviderAccountSnapshot(
            id: id, label: label, plan: displayPlanName, windows: windows, balances: balances,
            observedAt: observedAt ?? updatedAt, isStale: isStale)
    }
}
