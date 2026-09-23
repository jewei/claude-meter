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
    private let provider: GrokUsageProvider

    public init(provider: GrokUsageProvider = GrokUsageProvider()) {
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
            throw UsageProviderFailure(error)
        }
    }
}
