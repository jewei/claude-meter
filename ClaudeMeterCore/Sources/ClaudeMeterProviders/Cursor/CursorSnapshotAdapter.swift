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
    private let owned: CredentialBoundProvider<CursorCredentials>

    public init(provider: CursorUsageProvider = CursorUsageProvider()) {
        owned = CredentialBoundProvider(
            id: .cursor,
            load: { _ in try provider.loadCredentials() },
            fingerprint: {
                CredentialBoundProvider<CursorCredentials>.digest([
                    $0.accessToken, $0.refreshToken ?? "",
                ])
            },
            readUsage: {
                try await provider.fetchUsage(credentials: $0, now: $1).providerSnapshot()
            },
            retainsFailure: { error in
                switch error {
                case CursorError.notDetected, CursorError.unauthorized, CursorError.forbidden: false
                default: true
                }
            })
    }

    @MainActor
    public func validatePrevious(_ previous: ProviderSnapshot?, now: Date, refreshID: UUID)
        async throws
        -> ProviderSnapshot?
    {
        try await owned.validatePrevious(previous, now: now, refreshID: refreshID)
    }

    public func fetch(
        now: Date, previous: ProviderSnapshot? = nil, refreshID: UUID = UUID()
    ) async throws -> ProviderSnapshot {
        try await owned.fetch(now: now, previous: previous, refreshID: refreshID)
    }

    @MainActor
    public func didAccept(_ snapshot: ProviderSnapshot, refreshID: UUID) {
        owned.didAccept(snapshot, refreshID: refreshID)
    }
}
