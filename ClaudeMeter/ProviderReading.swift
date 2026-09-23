import ClaudeMeterCore
import Foundation

extension MainMeterReading {
    /// The menu bar still uses LimitInfo. Convert only the selected normalized
    /// observations here; provider wire models do not enter presentation.
    init?(account: ProviderAccountSnapshot, provider: MainMeterProvider, now: Date = Date()) {
        guard let observedAt = account.observedAt else { return nil }
        let windows = account.resolvedWindows(asOf: now).filter(\.contributesToQuota)
        func binding(_ kind: UsageWindowKind) -> UsageWindow? {
            windows.filter { $0.kind == kind }.max {
                ($0.usedPercent ?? -1) < ($1.usedPercent ?? -1)
            }
        }
        let session = binding(.session)
        let weekly = binding(.weekly)
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
