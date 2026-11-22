import Foundation
import MeterDomain
import MeterPlatform

/// Decodes the JSON response of `agy -p /usage --output-format json` into domain windows.
///
/// The primary model group (`Gemini Models`, or the first group when renamed) provides the
/// card's binding 5-hour and weekly windows. Additional model groups (such as Claude & GPT or
/// Gemini 4 Argon) become non-binding scoped windows shown in the card's details.
struct AntigravityUsageResponse: Equatable, Sendable {
    let plan: String?
    let windows: [QuotaWindow]

    init(data: Data) throws {
        guard let root = JSONValue.parse(data)?.objectValue else {
            throw AntigravityFailure.unexpectedResponse(detail: "Output was not a JSON object.")
        }
        let status = root["status"]?.text?.uppercased()
        if status == "ERROR" {
            let errorText = root["error"]?.text
            if Self.indicatesSignedOut(errorText) {
                throw AntigravityFailure.signedOut
            }
            throw AntigravityFailure.commandFailed(detail: errorText)
        }
        guard let command = root["command"]?.objectValue,
            let payload = command["data"]?.objectValue,
            let rawGroups = payload["groups"]?.arrayValue
        else {
            throw AntigravityFailure.unexpectedResponse(detail: "Missing command.data.groups.")
        }

        let groups = rawGroups.compactMap(Self.parseGroup)
        guard !groups.isEmpty else { throw AntigravityFailure.noQuota }

        let primaryIndex = Self.primaryGroupIndex(in: groups)
        var windows: [QuotaWindow] = []
        for (index, group) in groups.enumerated() {
            windows += Self.mapGroup(group, isPrimary: index == primaryIndex)
        }
        guard !windows.isEmpty else { throw AntigravityFailure.noQuota }
        self.plan = payload["plan"]?.text ?? payload["tier"]?.text
        self.windows = windows
    }

    func account(now: Date) -> AccountUsage {
        AccountUsage(
            id: .default, name: AntigravityProvider.accountName, plan: plan, windows: windows,
            observedAt: now, attemptedAt: now)
    }

    private static let signedOutMarkers = [
        "authentication required",
        "authentication failed",
        "please visit the url to log in",
        "not authenticated",
        "not logged in",
        "sign in",
        "unauthenticated",
    ]

    /// Maximum byte length of any marker in ``signedOutMarkers``, for sliding-window overlap.
    static let maxSignedOutMarkerBytes = signedOutMarkers.map(\.utf8.count).max() ?? 0

    /// Whether an error string from `agy` says the user needs to sign in.
    static func indicatesSignedOut(_ text: String?) -> Bool {
        guard let lower = text?.lowercased(), !lower.isEmpty else { return false }
        return signedOutMarkers.contains { lower.contains($0) }
    }

    // MARK: - Wire parsing

    private struct Group {
        let name: String
        let buckets: [Bucket]
    }

    private struct Bucket {
        let id: String
        let name: String?
        let windowKind: BucketWindow
        let usedPercent: Double
        let resetsAt: Date?
    }

    private enum BucketWindow: Equatable {
        case fiveHour
        case weekly
        case daily
        case other

        var duration: TimeInterval? {
            switch self {
            case .fiveHour: 5 * 3_600
            case .weekly: 7 * 86_400
            case .daily: 86_400
            case .other: nil
            }
        }

        var sortRank: Int {
            switch self {
            case .fiveHour: 0
            case .daily: 1
            case .weekly: 2
            case .other: 3
            }
        }

        init(_ raw: String?) {
            switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "5h", "5-hour", "5_hour", "five_hour": self = .fiveHour
            case "weekly", "7d", "week": self = .weekly
            case "daily", "24h", "day": self = .daily
            default: self = .other
            }
        }
    }

    private static func parseGroup(_ value: JSONValue) -> Group? {
        guard let object = value.objectValue,
            let rawBuckets = object["buckets"]?.arrayValue
        else { return nil }
        let name = object["name"]?.text ?? ""
        let buckets = rawBuckets.enumerated().compactMap { offset, item in
            parseBucket(item, groupName: name, index: offset)
        }
        guard !buckets.isEmpty else { return nil }
        return Group(name: name, buckets: buckets)
    }

    private static func parseBucket(_ value: JSONValue, groupName: String, index: Int) -> Bucket? {
        guard let object = value.objectValue,
            let remaining = object["remaining_fraction"]?.doubleValue,
            remaining.isFinite
        else { return nil }
        let used = (1 - remaining) * 100
        let windowKind = BucketWindow(object["window"]?.text)
        let id = object["id"]?.text ?? "\(groupName.lowercased())-\(index)"
        let resetsAt = DateParsing.date(object["reset_time"])
        return Bucket(
            id: id, name: object["name"]?.text, windowKind: windowKind, usedPercent: used,
            resetsAt: resetsAt)
    }

    private static func primaryGroupIndex(in groups: [Group]) -> Int {
        if let index = groups.firstIndex(where: { group in
            group.buckets.contains { $0.id == "gemini-5h" || $0.id == "gemini-weekly" }
        }) {
            return index
        }
        if let index = groups.firstIndex(where: { $0.name.lowercased() == "gemini models" }) {
            return index
        }
        return 0
    }

    private static func mapGroup(_ group: Group, isPrimary: Bool) -> [QuotaWindow] {
        let sorted = group.buckets.enumerated().sorted { lhs, rhs in
            if lhs.element.windowKind.sortRank != rhs.element.windowKind.sortRank {
                return lhs.element.windowKind.sortRank < rhs.element.windowKind.sortRank
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let shortName = shortGroupName(group.name)
        let hasMultipleWindows = Set(sorted.map(\.windowKind)).count > 1
        var usedSession = false
        var usedWeekly = false
        return sorted.map { bucket in
            if isPrimary {
                if bucket.windowKind == .fiveHour, !usedSession {
                    usedSession = true
                    return QuotaWindow(
                        id: bucket.id, title: primaryTitle(shortName, suffix: "5h"),
                        kind: .session, usedPercent: bucket.usedPercent,
                        resetsAt: bucket.resetsAt, isBinding: true,
                        duration: bucket.windowKind.duration)
                }
                if bucket.windowKind == .weekly, !usedWeekly {
                    usedWeekly = true
                    return QuotaWindow(
                        id: bucket.id, title: primaryTitle(shortName, suffix: "Weekly"),
                        kind: .weekly, usedPercent: bucket.usedPercent,
                        resetsAt: bucket.resetsAt, isBinding: true,
                        duration: bucket.windowKind.duration)
                }
            }
            let title = scopedTitle(
                group: shortName, bucket: bucket, hasMultipleWindows: hasMultipleWindows)
            return QuotaWindow(
                id: bucket.id, title: title, kind: .scoped, usedPercent: bucket.usedPercent,
                resetsAt: bucket.resetsAt, isBinding: false, duration: bucket.windowKind.duration)
        }
    }

    /// `"Gemini Models"` → `"Gemini"`, `"Claude and GPT models"` → `"Claude & GPT"`.
    private static func shortGroupName(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasSuffix(" models") {
            result = String(result.dropLast(" models".count))
        }
        return result.replacingOccurrences(of: " and ", with: " & ")
    }

    private static func primaryTitle(_ shortName: String, suffix: String) -> String {
        guard !shortName.isEmpty else { return suffix == "5h" ? "Session" : "Weekly" }
        return "\(shortName) \(suffix)"
    }

    private static func scopedTitle(
        group: String, bucket: Bucket, hasMultipleWindows: Bool
    ) -> String {
        guard !group.isEmpty else { return bucket.name ?? bucket.id }
        switch bucket.windowKind {
        case .fiveHour:
            return "\(group) 5h"
        case .daily:
            return "\(group) Daily"
        case .weekly:
            return hasMultipleWindows ? "\(group) 7d" : "\(group) Weekly"
        case .other:
            return bucket.name ?? group
        }
    }
}
