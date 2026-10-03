import ClaudeMeterCore
import Foundation

public enum ClaudeSnapshotAdapter {
    /// Account arrays are authoritative; legacy top-level fields are used only
    /// when that array is absent. User display overrides belong to the app.
    public static func snapshot(
        _ source: ClaudeUsageSnapshot, isStale: Bool = false
    ) -> ProviderSnapshot {
        let observedAt = source.lastSuccessfulPollAt ?? source.createdAt
        let accounts =
            source.accounts ?? [
                AccountUsage(
                    id: "claude", label: "Claude", account: source.account, limits: source.limits,
                    lastSuccessfulPollAt: observedAt, severity: source.state.severity)
            ]
        let normalized = accounts.map {
            account(
                $0, fallbackObservedAt: observedAt, sourceIsStale: source.state.isStale || isStale)
        }
        return ProviderSnapshot(
            provider: .claude, accounts: normalized,
            fetchedAt: normalized.compactMap(\.observedAt).max() ?? observedAt)
    }

    public static func account(
        _ source: AccountUsage, fallbackObservedAt: Date, sourceIsStale: Bool = false
    ) -> ProviderAccountSnapshot {
        let limits = source.limits
        func window(
            _ value: LimitWindow, id: String, title: String, kind: UsageWindowKind,
            contributesToQuota: Bool = true
        ) -> UsageWindow {
            UsageWindow(
                id: id, title: title, kind: kind,
                usedPercent: value.percentUsed, resetAt: value.resetsAt,
                contributesToQuota: contributesToQuota)
        }
        var windows = [
            window(limits.currentSession, id: "session", title: "Session", kind: .session),
            window(limits.currentWeekAllModels, id: "weekly", title: "Weekly", kind: .weekly),
        ]
        if let opus = limits.currentWeekOpus {
            windows.append(window(opus, id: "seven_day_opus", title: "Opus Weekly", kind: .scoped))
        }
        windows += (limits.scopedWeekly ?? []).map {
            window(
                $0.window, id: $0.id, title: "\($0.displayName) Weekly", kind: .scoped,
                contributesToQuota: false)
        }
        var balances: [BalanceItem] = []
        if let extra = limits.extraUsage {
            windows.append(
                UsageWindow(
                    id: "extra-usage", title: "Extra usage", kind: .billing,
                    usedPercent: extra.percentUsed, resetAt: nil, contributesToQuota: false))
            balances.append(
                BalanceItem(
                    id: "extra-usage", title: "Extra usage",
                    value: extra.usedMoney?.amount
                        ?? extra.usedAmount.flatMap { Decimal(string: String($0)) },
                    limit: extra.limitMoney?.amount
                        ?? extra.limitAmount.flatMap { Decimal(string: String($0)) },
                    unit: extra.currency?.uppercased(),
                    displayText: extra.isEnabled ? nil : "Paused"))
        }
        if let grants = limits.usageResets {
            // One detail row per reset, so the detail count matches the total.
            balances.append(
                BalanceItem(
                    id: "usage-resets", title: "Usage limit resets",
                    value: Decimal(grants.reduce(0) { $0 + $1.resetsLeft }), unit: "resets",
                    details: grants.flatMap { grant in
                        Array(
                            repeating: BalanceDetail(
                                title: grant.title, expiresAt: grant.expiresAt),
                            count: grant.resetsLeft)
                    }))
        }
        return ProviderAccountSnapshot(
            id: source.id, label: source.label, plan: source.account?.plan,
            subtitle: source.account?.email, windows: windows, balances: balances,
            observedAt: source.lastSuccessfulPollAt ?? fallbackObservedAt,
            isStale: sourceIsStale || source.isStale == true)
    }

    /// Folds the per-reset detail rows back into grants for the disk format.
    static func resetGrants(from details: [BalanceDetail]) -> [UsageResetGrant] {
        var grants: [UsageResetGrant] = []
        for detail in details {
            if let last = grants.last, last.title == detail.title,
                last.expiresAt == detail.expiresAt
            {
                grants[grants.count - 1].resetsLeft += 1
            } else {
                grants.append(
                    UsageResetGrant(title: detail.title, resetsLeft: 1, expiresAt: detail.expiresAt)
                )
            }
        }
        return grants
    }

    /// Compatibility is confined to disk serialization. Runtime selection uses accounts only.
    static func legacySnapshot(
        _ snapshot: ProviderSnapshot, organizations: [String: String], now: Date
    ) -> ClaudeUsageSnapshot? {
        let accounts = snapshot.accounts.compactMap { value -> AccountUsage? in
            guard let observed = value.observedAt else { return nil }
            func limit(_ window: UsageWindow?) -> LimitWindow {
                LimitWindow(
                    percentUsed: window?.isOverLimit == true ? 101 : window?.usedPercent,
                    resetsAt: window?.resetAt)
            }
            let balance = value.balances.first { $0.id == "extra-usage" }
            let extra = balance.map {
                ExtraUsage(
                    isEnabled: $0.displayText != "Paused",
                    usedCredits: $0.value.map { NSDecimalNumber(decimal: $0 * 100).doubleValue },
                    monthlyLimit: $0.limit.map { NSDecimalNumber(decimal: $0 * 100).doubleValue },
                    utilization: value.windows.first { $0.id == "extra-usage" }?.usedPercent,
                    currency: $0.unit)
            }
            let resets = value.balances.first { $0.id == "usage-resets" }.map {
                Self.resetGrants(from: $0.details ?? [])
            }
            let limits = LimitInfo(
                currentSession: limit(value.windows.first { $0.kind == .session }),
                currentWeekAllModels: limit(value.windows.first { $0.kind == .weekly }),
                currentWeekOpus: value.windows.first { $0.id == "seven_day_opus" }.map {
                    limit($0)
                },
                scopedWeekly: value.windows.filter {
                    $0.kind == .scoped && $0.id != "seven_day_opus"
                }.map { ScopedLimitWindow(id: $0.id, window: limit($0)) },
                extraUsage: extra,
                usageResets: resets)
            return AccountUsage(
                id: value.id, label: value.label,
                account: AccountInfo(
                    loginMethod: "OAuth", organization: organizations[value.id],
                    email: value.subtitle, plan: value.plan),
                limits: limits, lastSuccessfulPollAt: observed, severity: .unknown,
                isStale: value.isStale)
        }
        guard let first = accounts.first else { return nil }
        return ClaudeUsageSnapshot(
            parserVersion: "oauth-api-1.0", createdAt: now,
            lastSuccessfulPollAt: snapshot.fetchedAt,
            source: SourceInfo(cliPath: "api.anthropic.com", command: "GET /api/oauth/usage"),
            account: first.account, limits: first.limits,
            state: SnapshotState(
                status: .ok, isStale: accounts.allSatisfy { $0.isStale == true }, severity: .unknown
            ), accounts: accounts)
    }
}
