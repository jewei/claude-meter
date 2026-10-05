import Foundation
import MeterDomain
import MeterPlatform

/// Reads the results of `account/read` and `account/rateLimits/read` from `codex app-server`.
///
/// The shapes follow the upstream protocol types (`GetAccountResponse` and
/// `GetAccountRateLimitsResponse` in `openai/codex`, `codex-rs/app-server-protocol`).
/// `rateLimits` must be an object. Every field inside it is optional and isolated: a malformed
/// window drops only itself, and malformed metadata never discards a window.
enum CodexAppServerResult {
    /// The auth mode of the `account/read` result.
    static func authMode(account: JSONValue?) -> CodexAuthMode {
        CodexAuthMode(account?["account"]?["type"]?.text)
    }

    /// True when `account/read` answered `"account": null`: Codex has no login for the home.
    static func reportsNoAccount(_ account: JSONValue?) -> Bool {
        account?.objectValue?["account"] == .null
    }

    /// The owner of a login without an auth file, such as one that Codex keeps in the keyring:
    /// the ChatGPT email that `account/read` reports. It never leaves memory.
    static func owner(account: JSONValue?) -> AccountOwner? {
        guard authMode(account: account) == .chatGPT,
            let email = account?["account"]?["email"]?.text
        else { return nil }
        return .credential(Digest.sha256(parts: ["codex-app-server", email]))
    }

    static func quota(
        account: JSONValue?, rateLimits: JSONValue?, now: Date
    ) throws(CodexError) -> CodexQuota {
        guard let result = rateLimits?.objectValue, let limits = result["rateLimits"]?.objectValue
        else {
            throw .appServerUnexpected(detail: nil)
        }
        var quota = CodexQuota()
        quota.primary = window(limits["primary"])
        quota.secondary = window(limits["secondary"])
        if quota.primary == nil || quota.secondary == nil {
            // A sibling of `rateLimits`: one snapshot per metered limit ID.
            fillMissingSlots(
                &quota, from: result["rateLimitsByLimitId"] ?? result["rate_limits_by_limit_id"])
        }
        quota.credits = CodexQuota.credits(from: limits["credits"])
        let accountFields = account?["account"]
        quota.plan =
            limits["planType"]?.text ?? limits["plan_type"]?.text
            ?? accountFields?["planType"]?.text ?? accountFields?["plan_type"]?.text
        if let resets = result["rateLimitResetCredits"]?.objectValue,
            let count = resets["availableCount"]?.integerValue
        {
            quota.resetCount = count
            quota.resets = (resets["credits"]?.arrayValue ?? []).compactMap(resetRow(now: now))
        }
        guard quota.hasUsage else { throw .noUsageData }
        return quota
    }

    /// Positional windows win. Keyed snapshots fill only an empty slot: of their `primary` and
    /// `secondary` windows, the most used session window fills the primary slot, and the most
    /// used weekly window fills the secondary slot. A tie keeps the smallest limit ID.
    private static func fillMissingSlots(_ quota: inout CodexQuota, from keyed: JSONValue?) {
        var session: [CodexQuota.Window] = []
        var weekly: [CodexQuota.Window] = []
        for (_, value) in (keyed?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let snapshot = value.objectValue else { continue }
            for slot in [CodexQuota.Slot.primary, .secondary] {
                guard let window = window(snapshot[slot.rawValue]) else { continue }
                if CodexQuota.kind(of: window, slot: slot) == .session {
                    session.append(window)
                } else {
                    weekly.append(window)
                }
            }
        }
        if quota.primary == nil { quota.primary = mostUsed(session) }
        if quota.secondary == nil { quota.secondary = mostUsed(weekly) }
    }

    private static func mostUsed(_ windows: [CodexQuota.Window]) -> CodexQuota.Window? {
        windows.max { ($0.usedPercent ?? -1) < ($1.usedPercent ?? -1) }
    }

    /// One window, or nil when it is absent, has no `usedPercent`, or has a field of the wrong
    /// type. Upstream always sends `usedPercent`, so a window without it is not a window.
    private static func window(_ value: JSONValue?) -> CodexQuota.Window? {
        guard let fields = value?.objectValue else { return nil }
        do {
            guard let usedPercent = try JSONValue.strictNumber(fields["usedPercent"]) else {
                return nil
            }
            let minutes = try JSONValue.strictNumber(fields["windowDurationMins"])
            return CodexQuota.Window(
                usedPercent: usedPercent,
                resetsAt: try JSONValue.strictNumber(fields["resetsAt"])
                    .flatMap(DateBounds.date(secondsSince1970:)),
                duration: minutes.map { $0 * 60 })
        } catch {
            return nil
        }
    }

    /// Codex lists only available credits. A row with another status is dropped anyway, and
    /// a row without a status stays.
    private static func resetRow(now: Date) -> (JSONValue) -> ResetAllowance.Reset? {
        { value in
            guard let row = value.objectValue else { return nil }
            if let status = row["status"]?.text, status.lowercased() != "available" { return nil }
            return CodexUsageResponse.reset(
                title: row["title"], expiresAt: row["expiresAt"], now: now)
        }
    }
}
