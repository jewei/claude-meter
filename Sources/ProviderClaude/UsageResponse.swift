import Foundation
import MeterDomain
import MeterPlatform

/// The body of `GET /api/oauth/usage`. Decoding is lenient: a missing or malformed field is
/// unknown and never hides the other fields. Only a body that is not a JSON object fails.
struct UsageResponse: Sendable, Equatable {
    /// The body is not a JSON object.
    struct InvalidBody: Error {}

    struct Window: Sendable, Equatable {
        /// Percent used, 0 through 100 (values above 100 mean over the limit). Nil is unknown.
        let utilization: Double?
        let resetsAt: Date?
    }

    struct ScopedWindow: Sendable, Equatable {
        /// The API key, such as `seven_day_sonnet`.
        let key: String
        let window: Window
    }

    /// Pay-as-you-go spend beyond the plan. Amounts are in minor units, such as cents.
    struct ExtraUsage: Sendable, Equatable {
        static let defaultDecimalPlaces = 2

        let isEnabled: Bool
        let usedCredits: Double?
        let monthlyLimit: Double?
        /// 0 through 18. The API default is 2.
        let decimalPlaces: Int
        let utilization: Double?
        let currency: String?
    }

    struct ResetGrant: Sendable, Equatable {
        static let defaultTitle = "Usage reset"
        /// The most resets counted in total, over all grants. The mapper makes one entry per
        /// reset, so a huge response must not make millions of them.
        static let maxResets = 99

        let title: String
        let resetsLeft: Int
        let expiresAt: Date?
    }

    var fiveHour: Window?
    var sevenDay: Window?
    /// The Opus weekly window, only when it has a value.
    var sevenDayOpus: Window?
    /// Other `seven_day_<scope>` windows that have a value, sorted by key.
    var scoped: [ScopedWindow]
    var extraUsage: ExtraUsage?
    /// Usage-limit resets available now. Nil when unknown, empty when the account has none.
    var resetGrants: [ResetGrant]?

    init(
        fiveHour: Window? = nil, sevenDay: Window? = nil, sevenDayOpus: Window? = nil,
        scoped: [ScopedWindow] = [], extraUsage: ExtraUsage? = nil, resetGrants: [ResetGrant]? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.scoped = scoped
        self.extraUsage = extraUsage
        self.resetGrants = resetGrants
    }

    /// Decodes a response body. `now` filters reset grants that have not started or expired.
    init(data: Data, now: Date) throws(InvalidBody) {
        guard case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { throw InvalidBody() }
        self.init(
            fiveHour: Self.window(root["five_hour"]),
            sevenDay: Self.window(root["seven_day"]),
            extraUsage: Self.extraUsage(root["extra_usage"]),
            resetGrants: Self.resetGrants(root["cedar_ember"], now: now))

        // Model-scoped weekly windows are moving from flat `seven_day_<model>` fields into the
        // generic `limits` array, and the flat fields can turn null during the move. A flat
        // field with a value wins; `limits` fills the gaps.
        var windows = Self.scopedWindowsFromLimits(root["limits"])
        for (key, value) in root where Self.isScopedKey(key) {
            if let window = Self.window(value), window.utilization != nil {
                windows[key] = window
            }
        }
        sevenDayOpus = windows.removeValue(forKey: "seven_day_opus")
        scoped = windows.map { ScopedWindow(key: $0.key, window: $0.value) }
            .sorted { $0.key < $1.key }
    }

    /// `seven_day_<scope>` with a scope that has a letter or digit.
    private static func isScopedKey(_ key: String) -> Bool {
        let prefix = "seven_day_"
        return key.hasPrefix(prefix)
            && key.dropFirst(prefix.count).contains { $0.isLetter || $0.isNumber }
    }

    private static func window(_ value: JSONValue?) -> Window? {
        guard case .object(let entry)? = value else { return nil }
        return Window(
            utilization: number(entry["utilization"]),
            resetsAt: DateParsing.date(entry["resets_at"]))
    }

    /// `weekly_scoped` entries keyed like the flat fields: "Opus 4.5" becomes `seven_day_opus`.
    /// A leading "Claude" is skipped, so "Claude Opus 4" also becomes `seven_day_opus`. Other
    /// kinds mirror `five_hour` and `seven_day` and are ignored. The first entry per key wins,
    /// so a duplicated model cannot flip between refreshes.
    private static func scopedWindowsFromLimits(_ value: JSONValue?) -> [String: Window] {
        guard case .array(let entries)? = value else { return [:] }
        var windows: [String: Window] = [:]
        for case .object(let entry) in entries {
            guard entry["kind"]?.stringValue == "weekly_scoped",
                let displayName = entry["scope"]?["model"]?["display_name"]?.stringValue,
                let model = displayName.split(separator: " ").map({ $0.lowercased() })
                    .first(where: { $0 != "claude" }),
                let percent = number(entry["percent"])
            else { continue }
            let key = "seven_day_\(model)"
            if windows[key] == nil {
                windows[key] = Window(
                    utilization: percent, resetsAt: DateParsing.date(entry["resets_at"]))
            }
        }
        return windows
    }

    private static func extraUsage(_ value: JSONValue?) -> ExtraUsage? {
        guard case .object(let entry)? = value else { return nil }
        return ExtraUsage(
            isEnabled: entry["is_enabled"]?.boolValue ?? false,
            usedCredits: number(entry["used_credits"]),
            monthlyLimit: number(entry["monthly_limit"]),
            decimalPlaces: integer(entry["decimal_places"]).map { min(18, max(0, $0)) }
                ?? ExtraUsage.defaultDecimalPlaces,
            utilization: number(entry["utilization"]),
            currency: entry["currency"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty)
    }

    /// The `cedar_ember` allowance. `eligible: false` with reason `surface` means the server did
    /// not recognize the client, so the count is unknown; any other reason means the account is
    /// outside the program and has none. Keeps started, unexpired grants with resets left.
    private static func resetGrants(_ value: JSONValue?, now: Date) -> [ResetGrant]? {
        guard case .object(let allowance)? = value else { return nil }
        if allowance["eligible"] == .bool(false) {
            return allowance["ineligible_reason"] == .string("surface") ? nil : []
        }
        guard case .array(let items)? = allowance["grants"] else { return nil }
        var grants: [ResetGrant] = []
        var total = 0
        for item in items {
            guard case .object(let grant) = item else { return nil }
            // Grants after the limit change nothing, so they are not read.
            guard total < ResetGrant.maxResets else { break }
            guard let left = integer(grant["resets_left"]), left > 0 else { continue }
            if let startsAt = DateParsing.date(grant["starts_at"]), startsAt > now { continue }
            let expiresAt = DateParsing.date(grant["ends_at"])
            if let expiresAt, expiresAt <= now { continue }
            let label = grant["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let counted = min(left, ResetGrant.maxResets - total)
            total += counted
            grants.append(
                ResetGrant(
                    title: label?.nilIfEmpty ?? ResetGrant.defaultTitle, resetsLeft: counted,
                    expiresAt: expiresAt))
        }
        return grants
    }

    private static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value, number.isFinite else { return nil }
        return number
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        number(value).flatMap { Int(exactly: $0) }
    }
}
