import ClaudeMeterCore
import Foundation

extension CursorUsage {
    /// A single connection slot: this output has no opaque member ID. Do not use
    /// email or a credential fingerprint as an account key.
    public func providerSnapshot(isStale: Bool = false) -> ProviderSnapshot {
        var windows = [
            UsageWindow(
                id: "billing", title: "Billing period", kind: .billing,
                usedPercent: percentUsed, resetAt: periodEnd)
        ]
        for (id, title, percent) in [
            ("auto", "Auto + Composer", autoPercentUsed), ("api", "API", apiPercentUsed),
        ] where percent != nil {
            windows.append(
                UsageWindow(
                    id: id, title: title, kind: .scoped, usedPercent: percent,
                    resetAt: periodEnd, contributesToQuota: false))
        }
        let balances: [BalanceItem] =
            spendUsd == nil && limitUsd == nil
            ? []
            : [
                BalanceItem(
                    id: "billing", title: "Period spend",
                    value: spendUsd.flatMap { $0.isFinite ? Decimal(string: String($0)) : nil },
                    limit: limitUsd.flatMap { $0.isFinite ? Decimal(string: String($0)) : nil },
                    unit: "USD")
            ]
        return ProviderSnapshot(
            provider: .cursor,
            accounts: [
                ProviderAccountSnapshot(
                    id: "default", label: "Cursor", plan: displayPlanName, windows: windows,
                    balances: balances, observedAt: capturedAt, isStale: isStale)
            ], fetchedAt: capturedAt)
    }
}

/// Keeps credential and wire errors behind the normalized fetch contract.
public struct CursorProviderAdapter: UsageProvider {
    public let id: ProviderID = .cursor
    private let provider: CursorUsageProvider

    public init(provider: CursorUsageProvider = CursorUsageProvider()) {
        self.provider = provider
    }

    public func fetch(
        now: Date, previous: ProviderSnapshot? = nil, refreshID: UUID = UUID()
    ) async throws -> ProviderSnapshot {
        do {
            return try await provider.fetchUsage(now: now).providerSnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let retainsLastGood: Bool
            switch error {
            case CursorError.notDetected, CursorError.unauthorized, CursorError.forbidden:
                retainsLastGood = false
            default:
                retainsLastGood = true
            }
            throw UsageProviderFailure(error, retainsLastGood: retainsLastGood)
        }
    }
}
