import Foundation

public enum TokenUsagePeriod: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case lastSevenDays = "Last 7 Days"

    public func interval(asOf now: Date, calendar: Calendar) -> DateInterval? {
        guard PersistedDateBounds.contains(now) else { return nil }
        let today = calendar.startOfDay(for: now)
        let offset = self == .yesterday ? -1 : (self == .lastSevenDays ? -6 : 0)
        guard let start = calendar.date(byAdding: .day, value: offset, to: today),
            let end = calendar.date(byAdding: .day, value: self == .yesterday ? 0 : 1, to: today),
            PersistedDateBounds.contains(start), PersistedDateBounds.contains(end)
        else { return nil }
        return DateInterval(start: start, end: end)
    }
}

/// Counts cover retained local tool records or Cursor's account export, never quota.
public struct TokenUsageSnapshot: Equatable, Sendable {
    public let provider: ProviderID
    public let daily: [Date: Int64]
    public let periodStart: Date
    public let observedAt: Date
    public let timeZoneID: String
    public let hasRecords: Bool
    public let isPartial: Bool
    /// Local history by account key. Records belong to the account whose folder holds them.
    /// Empty when the whole source belongs to one account, as Cursor's export does.
    public let accounts: [String: TokenUsageSnapshot]

    public init(
        provider: ProviderID, daily: [Date: Int64], periodStart: Date, observedAt: Date,
        timeZoneID: String, hasRecords: Bool = true, isPartial: Bool = false,
        accounts: [String: TokenUsageSnapshot] = [:]
    ) {
        self.provider = provider
        self.daily = daily.filter { PersistedDateBounds.contains($0.key) && $0.value >= 0 }
        self.periodStart = periodStart
        self.observedAt = observedAt
        self.timeZoneID = timeZoneID
        self.hasRecords = hasRecords
        self.isPartial = isPartial || self.daily.count != daily.count
        self.accounts = accounts
    }

    /// The history for one account card. An account without a local folder has no records.
    public func account(_ id: String) -> TokenUsageSnapshot {
        guard !accounts.isEmpty else { return self }
        return accounts[id]
            ?? TokenUsageSnapshot(
                provider: provider, daily: [:], periodStart: periodStart,
                observedAt: observedAt, timeZoneID: timeZoneID, hasRecords: false)
    }

    public func tokens(
        for period: TokenUsagePeriod, asOf now: Date, calendar: Calendar = .current
    ) -> Int64? {
        guard hasRecords, timeZoneID == calendar.timeZone.identifier,
            PersistedDateBounds.contains(periodStart), PersistedDateBounds.contains(observedAt),
            let interval = period.interval(asOf: now, calendar: calendar),
            periodStart <= interval.start, observedAt >= interval.start
        else { return nil }
        var total: Int64 = 0
        for (day, count) in daily where day >= interval.start && day < interval.end {
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}

/// Optional token history has its own acceptance and freshness, independent of quota.
public protocol TokenUsageSource: Sendable {
    var id: ProviderID { get }
    @MainActor func validatePrevious(
        _ previous: TokenUsageSnapshot?, refreshID: UUID
    ) async throws -> TokenUsageSnapshot?
    func fetch(now: Date, refreshID: UUID) async throws -> TokenUsageSnapshot
    @MainActor func didAccept(_ snapshot: TokenUsageSnapshot, refreshID: UUID)
}

extension TokenUsageSource {
    @MainActor public func validatePrevious(
        _ previous: TokenUsageSnapshot?, refreshID: UUID
    ) async throws -> TokenUsageSnapshot? { previous }
    @MainActor public func didAccept(_ snapshot: TokenUsageSnapshot, refreshID: UUID) {}
}
