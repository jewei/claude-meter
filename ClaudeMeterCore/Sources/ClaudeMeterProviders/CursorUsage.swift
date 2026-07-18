import ClaudeMeterCore
import Foundation

/// Cursor billing-period usage, normalized for display.
///
/// Cursor bills on a monthly period (not Claude's rolling session/week windows),
/// so this is a single snapshot: percent of the plan limit used, dollar spend,
/// and the period reset date.
public struct CursorUsage: Codable, Equatable, Sendable {
    public var percentUsed: Double?  // 0–100
    public var autoPercentUsed: Double?  // 0–100, Auto + Composer bucket
    public var apiPercentUsed: Double?  // 0–100, named-model API bucket
    public var spendUsd: Double?  // dollars used this period
    public var limitUsd: Double?  // plan limit in dollars (nil = no fixed limit)
    public var periodEnd: Date?  // billing cycle end
    public var planName: String?
    public var email: String?
    public var capturedAt: Date

    public init(
        percentUsed: Double? = nil,
        autoPercentUsed: Double? = nil,
        apiPercentUsed: Double? = nil,
        spendUsd: Double? = nil,
        limitUsd: Double? = nil,
        periodEnd: Date? = nil,
        planName: String? = nil,
        email: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.percentUsed = percentUsed
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
        self.spendUsd = spendUsd
        self.limitUsd = limitUsd
        self.periodEnd = periodEnd
        self.planName = planName
        self.email = email
        self.capturedAt = capturedAt
    }

    public var clampedPercent: Double? {
        percentUsed.map { min(100, max(0, $0)) }
    }

    public var clampedAutoPercent: Double? {
        autoPercentUsed.map { min(100, max(0, $0)) }
    }

    public var clampedAPIPercent: Double? {
        apiPercentUsed.map { min(100, max(0, $0)) }
    }

    public var displayPlanName: String? {
        guard let planName else { return nil }
        let trimmed = planName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "free": return "Free"
        case "pro": return "Pro"
        case "pro_plus", "pro+": return "Pro+"
        case "ultra": return "Ultra"
        case "business": return "Business"
        case "team", "teams": return "Teams"
        default: return trimmed
        }
    }

    /// Dollars spent this cycle, e.g. "$12.40". We deliberately avoid a
    /// "spent / limit" ratio: Cursor grants free bonus credit beyond the plan
    /// limit, so `totalPercentUsed` (the percent field) is the authoritative
    /// figure while raw spend can exceed the nominal limit.
    public var spendText: String? {
        spendUsd.map(Self.dollars)
    }

    private static func dollars(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

// MARK: - API response decoding

/// `GetCurrentPeriodUsage` response from `api2.cursor.sh`.
struct CursorUsageResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: PlanUsage?
    let enabled: Bool?

    struct PlanUsage: Decodable {
        let totalSpend: Int?  // cents
        let limit: Int?  // cents
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    /// Maps the raw response to a normalized `CursorUsage`. Spend/limit are cents.
    func usage(planName: String?, email: String?, now: Date) -> CursorUsage {
        CursorUsage(
            percentUsed: planUsage?.totalPercentUsed,
            autoPercentUsed: planUsage?.autoPercentUsed,
            apiPercentUsed: planUsage?.apiPercentUsed,
            spendUsd: planUsage?.totalSpend.map { Double($0) / 100 },
            limitUsd: planUsage?.limit.flatMap { $0 > 0 ? Double($0) / 100 : nil },
            periodEnd: parseEpochOrISODate(billingCycleEnd),
            planName: planName,
            email: email,
            capturedAt: now
        )
    }

    /// Validates API flags before mapping to display state.
    func validatedUsage(planName: String?, email: String?, now: Date) throws -> CursorUsage {
        if enabled == false { throw CursorError.usageDisabled }
        return usage(planName: planName, email: email, now: now)
    }

}

/// `GetPlanInfo` response (optional companion call for the plan label).
struct CursorPlanInfoResponse: Decodable {
    let planInfo: PlanInfo?
    struct PlanInfo: Decodable { let planName: String? }
}

/// `oauth/token` refresh response.
struct CursorOAuthResponse: Decodable {
    let accessToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}
