import Foundation
import MeterDomain
import MeterPlatform

/// Reads the results of `account/read` and `account/rateLimits/read` from `codex app-server`.
///
/// `rateLimits` must be an object. Every field inside it is optional and isolated: a malformed
/// window drops only itself, and malformed metadata never discards a window.
enum CodexAppServerResult {
    /// The auth mode of the `account/read` result.
    static func authMode(account: JSONValue?) -> CodexAuthMode {
        CodexAuthMode(account?["account"]?["type"]?.text)
    }

    static func quota(
        account: JSONValue?, rateLimits: JSONValue?, now: Date
    ) throws(CodexError) -> CodexQuota {
        guard let limits = rateLimits?["rateLimits"]?.objectValue else {
            throw .appServerUnexpected
        }
        var quota = CodexQuota()
        quota.primary = window(limits["primary"])
        quota.secondary = window(limits["secondary"])
        if quota.primary == nil || quota.secondary == nil {
            fillMissingSlots(
                &quota, from: limits["rateLimitsByLimitId"] ?? limits["rate_limits_by_limit_id"])
        }
        quota.credits = CodexQuota.credits(from: limits["credits"])
        let accountFields = account?["account"]
        quota.plan =
            limits["planType"]?.text ?? limits["plan_type"]?.text
            ?? accountFields?["planType"]?.text ?? accountFields?["plan_type"]?.text
        if let resets = rateLimits?["rateLimitResetCredits"]?.objectValue,
            let count = resets["availableCount"]?.integerValue
        {
            quota.resetCount = count
            quota.resets = (resets["credits"]?.arrayValue ?? []).compactMap { row in
                guard let row = row.objectValue else { return nil }
                return CodexUsageResponse.reset(
                    title: row["title"], expiresAt: row["expiresAt"], now: now)
            }
        }
        guard quota.hasUsage else { throw .noUsageData }
        return quota
    }

    /// Positional windows win. Keyed windows fill only an empty slot: the most used window of
    /// at most 24 hours fills the primary slot, and the most used longer window fills the
    /// secondary slot. A tie keeps the smallest limit ID.
    private static func fillMissingSlots(_ quota: inout CodexQuota, from keyed: JSONValue?) {
        let windows = (keyed?.objectValue ?? [:]).sorted { $0.key < $1.key }
            .compactMap { window($0.value) }
        let session = windows.filter { ($0.duration ?? 0) <= CodexQuota.sessionLimit }
        let weekly = windows.filter { ($0.duration ?? 0) > CodexQuota.sessionLimit }
        if quota.primary == nil { quota.primary = mostUsed(session) }
        if quota.secondary == nil { quota.secondary = mostUsed(weekly) }
    }

    private static func mostUsed(_ windows: [CodexQuota.Window]) -> CodexQuota.Window? {
        windows.max { ($0.usedPercent ?? -1) < ($1.usedPercent ?? -1) }
    }

    /// One window, or nil when it is absent or any of its fields has the wrong type.
    private static func window(_ value: JSONValue?) -> CodexQuota.Window? {
        guard let fields = value?.objectValue else { return nil }
        do {
            let minutes = try JSONValue.strictNumber(fields["windowDurationMins"])
            return CodexQuota.Window(
                usedPercent: try JSONValue.strictNumber(fields["usedPercent"]),
                resetsAt: try JSONValue.strictNumber(fields["resetsAt"])
                    .flatMap(DateBounds.date(secondsSince1970:)),
                duration: minutes.map { $0 * 60 })
        } catch {
            return nil
        }
    }
}
