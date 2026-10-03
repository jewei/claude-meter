import ClaudeMeterCore
import Foundation

extension GrokUsage {
    /// Grok currently exposes one connection slot and no plan or opaque member ID.
    public func providerSnapshot(isStale: Bool = false) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .grok,
            accounts: [
                ProviderAccountSnapshot(
                    id: "default", label: "Grok",
                    windows: [
                        UsageWindow(
                            id: "credits", title: windowLabel, kind: .billing,
                            usedPercent: usedPercent, resetAt: resetsAt)
                    ],
                    balances: [
                        BalanceItem(
                            id: "on-demand", title: "On-demand",
                            value: Decimal(onDemandUsedCents) / 100,
                            limit: onDemandCapCents > 0 ? Decimal(onDemandCapCents) / 100 : nil,
                            unit: "USD"),
                        BalanceItem(
                            id: "prepaid", title: "Prepaid balance",
                            value: Decimal(prepaidBalanceCents) / 100, unit: "USD"),
                    ], observedAt: updatedAt, isStale: isStale)
            ], fetchedAt: updatedAt)
    }
}

public struct GrokProviderAdapter: UsageProvider {
    public let id: ProviderID = .grok
    private let owned: CredentialBoundProvider<GrokCredentials>

    public init(provider: GrokUsageProvider = GrokUsageProvider()) {
        owned = CredentialBoundProvider(
            id: .grok,
            load: { try provider.loadCredentials(now: $0) },
            fingerprint: { CredentialBoundProvider<GrokCredentials>.digest([$0.bearer]) },
            readUsage: {
                try await provider.fetchUsage(credentials: $0, now: $1).providerSnapshot()
            },
            retainsFailure: { error in
                switch error {
                case GrokAuthError.missing, GrokAuthError.loginRequired: false
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
