import Foundation
import MeterDomain
import MeterPlatform

/// Reads the `wham/usage` response.
///
/// Quota is strict: a present window with a value of the wrong type fails the read, so a
/// changed format never shows as unknown usage. Plan, credits, and reset metadata are
/// optional: a malformed value is dropped and the windows stay.
enum CodexUsageResponse {
    static func quota(from body: Data) throws(CodexError) -> CodexQuota {
        guard let fields = JSONValue.parse(body)?.objectValue else {
            throw .unexpectedResponse
        }
        var quota = CodexQuota()
        do {
            switch fields["rate_limit"] {
            case nil, .null?:
                break
            case .object(let limits)?:
                quota.primary = try window(limits["primary_window"])
                quota.secondary = try window(limits["secondary_window"])
            default:
                throw MalformedValue()
            }
        } catch {
            throw .unexpectedResponse
        }
        quota.plan = fields["plan_type"]?.text
        quota.credits = CodexQuota.credits(from: fields["credits"])
        quota.resetCount = fields["rate_limit_reset_credits"]?["available_count"]?.integerValue
        guard quota.hasUsage else { throw .noUsageData }
        return quota
    }

    private static func window(_ value: JSONValue?) throws(MalformedValue) -> CodexQuota.Window? {
        switch value {
        case nil, .null?:
            return nil
        case .object(let fields)?:
            return CodexQuota.Window(
                usedPercent: try JSONValue.strictNumber(fields["used_percent"]),
                resetsAt: try JSONValue.strictNumber(fields["reset_at"])
                    .flatMap(DateBounds.date(secondsSince1970:)),
                duration: try JSONValue.strictNumber(fields["limit_window_seconds"]))
        default:
            throw MalformedValue()
        }
    }

    /// Reset-credit details from `wham/rate-limit-reset-credits`.
    ///
    /// Nil unless the response's count equals `expectedCount`, so a different inventory never
    /// attaches. Keeps only rows that are available and not expired at `now`. A row with an
    /// unknown expiry stays.
    static func resets(
        from body: Data, expectedCount: Int, now: Date
    ) -> [ResetAllowance.Reset]? {
        guard let fields = JSONValue.parse(body)?.objectValue,
            fields["available_count"]?.integerValue == expectedCount,
            let rows = fields["credits"]?.arrayValue
        else { return nil }
        return rows.compactMap { row in
            guard let row = row.objectValue, row["status"]?.text?.lowercased() == "available"
            else { return nil }
            return reset(title: row["title"], expiresAt: row["expires_at"], now: now)
        }
    }

    /// One reset row, or nil when it has expired. Both sources use it.
    static func reset(title: JSONValue?, expiresAt: JSONValue?, now: Date) -> ResetAllowance.Reset?
    {
        let expiry = DateParsing.date(expiresAt)
        if let expiry, expiry <= now { return nil }
        return ResetAllowance.Reset(title: title?.text ?? "Usage reset", expiresAt: expiry)
    }
}
