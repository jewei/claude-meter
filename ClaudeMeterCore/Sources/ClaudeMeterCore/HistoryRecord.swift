import Foundation

public struct HistoryRecord: Identifiable, Codable, Sendable {
    public let id: Int64
    public let createdAt: Date
    public let sessionPercent: Double?
    public let weekPercent: Double?
    public let sessionResetsAt: Date?
    public let weekResetsAt: Date?
    public let severity: String
    public let model: String?

    public init(
        id: Int64 = 0,
        createdAt: Date,
        sessionPercent: Double?,
        weekPercent: Double?,
        sessionResetsAt: Date?,
        weekResetsAt: Date?,
        severity: String,
        model: String?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sessionPercent = sessionPercent
        self.weekPercent = weekPercent
        self.sessionResetsAt = sessionResetsAt
        self.weekResetsAt = weekResetsAt
        self.severity = severity
        self.model = model
    }
}

extension HistoryRecord {
    public init(
        from snapshot: ClaudeUsageSnapshot,
        thresholds: UsageThresholds = .default,
        privacyMode: PrivacyMode = .workSafe
    ) {
        let sev = UsageSeverity.highest(
            thresholds.severity(for: snapshot.limits.currentSession.percentUsed),
            thresholds.severity(for: snapshot.limits.currentWeekAllModels.percentUsed)
        )
        self.init(
            createdAt: snapshot.lastSuccessfulPollAt ?? snapshot.createdAt,
            sessionPercent: snapshot.limits.currentSession.percentUsed,
            weekPercent: snapshot.limits.currentWeekAllModels.percentUsed,
            sessionResetsAt: snapshot.limits.currentSession.resetsAt,
            weekResetsAt: snapshot.limits.currentWeekAllModels.resetsAt,
            severity: sev.rawValue,
            model: privacyMode.showsModel ? snapshot.session?.activeModel : nil
        )
    }
}
