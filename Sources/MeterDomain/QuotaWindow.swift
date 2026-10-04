import Foundation

/// One usage limit reported by a provider, such as a 5-hour session or a weekly cap.
///
/// Percentages always mean *used*, from 0 through 100. A provider value above 100 is stored as
/// 100 with ``isOverLimit`` set, so severity survives the clamp. Presentation converts used to
/// energy left.
public struct QuotaWindow: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A short rolling window, 24 hours or less (Claude's 5-hour session).
        case session
        /// A long rolling window, more than 24 hours.
        case weekly
        /// A window limited to one model or feature, such as Claude's Opus weekly cap.
        case scoped
        /// A billing period, such as Cursor's monthly plan usage.
        case billing
    }

    public let id: String
    public let title: String
    public let kind: Kind
    /// Percent used, 0...100. Nil when the provider reports no usable value.
    public let usedPercent: Double?
    /// The provider reported more than 100% used.
    public let isOverLimit: Bool
    /// When the provider says the window resets or ends. Never predicted.
    public let resetsAt: Date?
    /// Whether the window limits the account. Binding windows select the main account and set
    /// severity. Informational windows, such as most scoped caps and Claude's extra usage, only
    /// display. A billing window can bind: Cursor's billing period and Grok's credits set the
    /// severity of their cards. ``ProviderID/canOwnMenuBar`` keeps those providers out of the
    /// menu bar.
    public let isBinding: Bool

    public init(
        id: String,
        title: String,
        kind: Kind,
        usedPercent: Double?,
        resetsAt: Date?,
        isBinding: Bool = true,
        isOverLimit: Bool = false
    ) {
        let used = usedPercent.flatMap { $0.isFinite ? $0 : nil }
        self.id = id
        self.title = title
        self.kind = kind
        self.usedPercent = used.map { $0.clamped(to: 0...100) }
        self.isOverLimit = used.map { isOverLimit || $0 > 100 } ?? false
        self.resetsAt = DateBounds.validated(resetsAt)
        self.isBinding = isBinding
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            kind: try container.decode(Kind.self, forKey: .kind),
            usedPercent: try container.decodeIfPresent(Double.self, forKey: .usedPercent),
            resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt),
            isBinding: try container.decode(Bool.self, forKey: .isBinding),
            isOverLimit: try container.decode(Bool.self, forKey: .isOverLimit))
    }

    /// Percent of the limit still available, 0...100.
    public var percentLeft: Double? {
        usedPercent.map { 100 - $0 }
    }

    /// The window as it applies at `now`.
    ///
    /// Windows roll over at `resetsAt`. After that instant a current reading has reset to 0%
    /// used, and the next reset time is unknown. A stale reading cannot know what happened
    /// after the reset, so it becomes unknown. Resolution is idempotent.
    public func resolved(at now: Date, isStale: Bool) -> QuotaWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        return QuotaWindow(
            id: id, title: title, kind: kind,
            usedPercent: isStale ? nil : usedPercent.map { _ in 0 },
            resetsAt: nil, isBinding: isBinding)
    }

    public func severity(_ thresholds: Thresholds) -> Severity {
        thresholds.severity(usedPercent: usedPercent, isOverLimit: isOverLimit)
    }

    /// Orders windows by how constrained they are. Over the limit ranks above 100%, and an
    /// unknown value ranks below a known 0%.
    public var pressure: Double {
        if isOverLimit { return 101 }
        return usedPercent ?? -1
    }
}
