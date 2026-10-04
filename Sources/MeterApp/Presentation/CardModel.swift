import Foundation
import MeterDomain

/// One card in the popover. Every provider uses this shape; views render it without deciding
/// anything about the data.
public struct CardModel: Identifiable, Equatable, Sendable {
    public enum Disclosure: Equatable, Sendable {
        /// Always shows its details (ring cards).
        case alwaysOpen
        case collapsed
        case expanded

        public var showsDetails: Bool { self != .collapsed }
    }

    public enum Summary: Equatable, Sendable {
        case rings(RingsModel)
        case bars(BarsModel)
        case extraUsage(ExtraUsageModel)
    }

    public let id: CardID
    public let provider: ProviderID
    public let title: String
    public let plan: PlanBadge?
    public let sharesLogin: Bool
    /// The card that owns the menu bar. It is always first.
    public let isMain: Bool
    public let disclosure: Disclosure
    public let summary: Summary
    /// Shown when ``disclosure`` shows details.
    public let details: [DetailSection]
    public let status: StatusLine?
}

/// One limit window, ready to render as a ring, a bar, or a row.
public struct GaugeModel: Equatable, Sendable {
    /// `Session`, `Weekly`, `Opus Weekly`.
    public let title: String
    /// `5-hr`, `week`, `opus` for compact ring rows.
    public let shortTitle: String
    /// `60%` or `—`.
    public let valueText: String
    /// `left` or `used`, or nil when the value is unknown.
    public let caption: String?
    /// The share to fill, 0...1.
    public let fraction: Double
    public let severity: Severity
    /// `Resets in 3h 12m`.
    public let resetText: String?
    /// `60 percent left, full energy, resets in 3h 12m`.
    public let accessibilityValue: String
}

public struct RingsModel: Equatable, Sendable {
    /// The weekly window, drawn as the outer ring.
    public let outer: GaugeModel
    /// The session window, drawn as the inner ring.
    public let inner: GaugeModel
    public let initial: String
    /// One row per window: session, weekly, then scoped windows.
    public let rows: [GaugeModel]
}

public struct BarsModel: Equatable, Sendable {
    /// The number in the card header.
    public let headline: GaugeModel
    public let bars: [GaugeModel]
    /// `12 credits · 1 usage reset available`.
    public let caption: String?
    /// Each bar has its own label row: `Session · 60% left` and its reset. False when the
    /// caption already states the window and its reset (Cursor, Grok).
    public let showsBarLabels: Bool
}

/// Claude extra usage: money spent of a monthly limit, drawn like every other limit. The bar
/// is the budget as energy: it fills with the share of the limit left (or spent, in Usage
/// mode) and takes the severity color of the share spent, so it drains and turns red as the
/// money goes, and never reads as full energy at the limit.
public struct ExtraUsageModel: Equatable, Sendable {
    /// `$12.34 / $50.00`: spent of the limit.
    public let amountText: String
    public let isPaused: Bool
    /// The share of the limit to fill, 0...1, following the meter mode. Nil without a limit
    /// share.
    public let fraction: Double?
    /// The severity of the share spent, from the user's thresholds.
    public let severity: Severity
    /// `75% left` or `25% used`, when the share is known.
    public let shareText: String?
    /// `$12.34 spent of $50.00, 75 percent left, full energy`.
    public let accessibilityValue: String
}

public enum DetailSection: Equatable, Sendable {
    /// Further limit windows, such as Opus and other scoped weekly caps.
    case limits([GaugeModel])
    /// Usage split rows, such as Cursor's Auto and API usage.
    case usageBars([GaugeModel])
    case resets(ResetsModel)
    case tokens(TokenRowsModel)
}

public struct PlanBadge: Equatable, Sendable {
    public enum Tier: Equatable, Sendable {
        case max, pro, free
    }

    public let text: String
    public let tier: Tier

    /// Badge text and color for a plan name: `Max 20x` → `MAX 20X` in the max color.
    public init?(plan: String?, verbatim: Bool = false) {
        guard let plan = plan?.trimmingCharacters(in: .whitespaces), !plan.isEmpty else {
            return nil
        }
        let lower = plan.lowercased()
        let tier: Tier =
            if lower.contains("max") || lower.contains("enterprise") {
                .max
            } else if ["team", "business", "pro", "plus"].contains(where: lower.contains)
                || lower == "go"
            {
                .pro
            } else {
                .free
            }
        self.tier = tier
        if verbatim || lower.wholeMatch(of: /(max|pro) [0-9]+x/) != nil {
            text = plan.uppercased()
        } else if let word = ["max", "enterprise", "team", "business", "pro", "plus"]
            .first(where: lower.contains)
        {
            text = word.uppercased()
        } else if lower.contains("free") {
            text = "FREE"
        } else {
            text = plan.uppercased()
        }
    }
}

public struct StatusLine: Equatable, Sendable {
    public let text: String
    /// A failure, shown in warning color. Otherwise informational.
    public let isFailure: Bool
}

public struct ResetsModel: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let title: String
        /// `Expires in 2d 3h`, `Expired`, or `Expiry date not provided`.
        public let expiryText: String
        /// The exact local expiry, for a tooltip.
        public let help: String
    }

    /// `3 available` or `Not reported`.
    public let countText: String
    public let rows: [Row]
    public let note: String?

    /// `2 usage resets available`, for collapsed bar cards.
    public let summary: String?
}

public struct TokenRowsModel: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let title: String
        /// `35.8M tokens` or `—`.
        public let value: String
        public let accessibilityValue: String
        public let help: String
    }

    /// `This Mac` or `Account usage`.
    public let sourceLabel: String
    public let help: String
    public let rows: [Row]
    public let note: String?
}
