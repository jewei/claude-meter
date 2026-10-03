import ClaudeMeterCore
import Foundation

extension ProviderAccountSnapshot {
    func bindingWindow(_ kind: UsageWindowKind) -> UsageWindow? {
        windows.filter { $0.kind == kind && $0.contributesToQuota }.max {
            let left = $0.isOverLimit ? 101 : $0.usedPercent ?? -1
            let right = $1.isOverLimit ? 101 : $1.usedPercent ?? -1
            if left != right { return left < right }
            guard let leftReset = $0.resetAt else { return false }
            guard let rightReset = $1.resetAt else { return true }
            return leftReset < rightReset
        }
    }

    /// A derived display value. The store keeps the original observation unchanged.
    func forPresentation(
        asOf now: Date, providerIsStale: Bool = false, defaults: UserDefaults = .standard
    ) -> ProviderAccountSnapshot {
        let stale =
            isStale || providerIsStale
            || MeterSettings.isSnapshotStale(lastPollAt: observedAt, defaults: defaults, now: now)
        return ProviderAccountSnapshot(
            id: id, label: label, plan: plan, subtitle: subtitle,
            windows: windows.map { $0.resolved(asOf: now, isStale: stale) },
            balances: balances, observedAt: observedAt, isStale: stale,
            lastError: lastError, lastAttemptAt: lastAttemptAt)
    }
}

extension MainMeterReading {
    /// The menu bar still uses LimitInfo. Convert only the selected normalized
    /// observations here; provider wire models do not enter presentation.
    init?(
        account: ProviderAccountSnapshot, provider: MainMeterProvider, now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let account = account.forPresentation(asOf: now, defaults: defaults)
        guard let observedAt = account.observedAt else { return nil }
        let windows = account.resolvedWindows(asOf: now).filter(\.contributesToQuota)
        let session = account.bindingWindow(.session)
        let weekly = account.bindingWindow(.weekly)
        func limit(_ window: UsageWindow?) -> LimitWindow {
            LimitWindow(
                percentUsed: window?.isOverLimit == true ? 101 : window?.usedPercent,
                resetsAt: window?.resetAt)
        }
        self.init(
            provider: provider, accountID: account.id, accountLabel: account.label,
            plan: account.plan,
            limits: LimitInfo(
                currentSession: limit(session), currentWeekAllModels: limit(weekly),
                currentWeekOpus: windows.first { $0.kind == .scoped && $0.contributesToQuota }.map {
                    limit($0)
                }),
            sessionLabel: session?.title ?? "5h", weeklyLabel: weekly?.title ?? "7d",
            observedAt: observedAt, sourceMarkedStale: account.isStale)
    }
}

extension AccountCardModel {
    init(account: ProviderAccountSnapshot, now: Date, providerError: String? = nil) {
        let account = account.forPresentation(asOf: now)
        func limit(_ window: UsageWindow?) -> LimitWindow {
            LimitWindow(
                percentUsed: window?.isOverLimit == true ? 101 : window?.usedPercent,
                resetsAt: window?.resetAt)
        }
        let windows = account.windows
        self.init(
            id: account.id, label: account.label, plan: account.plan, subtitle: account.subtitle,
            session: limit(account.bindingWindow(.session)),
            week: limit(account.bindingWindow(.weekly)),
            opus: windows.first { $0.id == "seven_day_opus" }.map { limit($0) },
            usageResets: account.balances.first { $0.id == "usage-resets" },
            scoped: windows.filter { $0.kind == .scoped && $0.id != "seven_day_opus" }.map {
                ScopedLimitWindow(id: $0.id, window: limit($0))
            },
            lastError: account.lastError, providerError: providerError, isStale: account.isStale)
    }
}
