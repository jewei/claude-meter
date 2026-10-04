import Foundation

extension GaugeModel {
    /// The window has a value. Without one, ``valueText`` is `—`, which views set in the
    /// body face, because the display face draws it like a minus sign.
    public var hasValue: Bool { caption != nil }

    /// `60% left`, `25% used`, or `—`.
    public var valueWithCaption: String {
        [valueText, caption].compactMap { $0 }.joined(separator: " ")
    }

    /// `Session · 60% left`, the label under a bar.
    public var summaryText: String {
        "\(title) · \(valueWithCaption)"
    }
}

/// The key beside "ACCOUNTS" in ring style. It uses the rows' own short titles.
public struct RingLegendModel: Equatable, Sendable {
    /// The outer ring: the weekly window.
    public let outer: String
    /// The inner ring: the session window.
    public let inner: String
    public let accessibilityLabel: String

    static let standard = RingLegendModel(
        outer: GaugeBuilder.weeklyShortTitle, inner: GaugeBuilder.sessionShortTitle,
        accessibilityLabel: "Outer ring weekly, inner ring session")
}

extension AccountsModel {
    /// The ring legend, when any card is drawn as rings.
    public var ringLegend: RingLegendModel? {
        showsRingLegend ? .standard : nil
    }
}

/// Text for the severity thresholds in Settings > Appearance.
public enum ThresholdText {
    /// `80%`: the threshold inside its range, as a whole number.
    public static func percent(_ value: Double, in range: ClosedRange<Double>) -> String {
        "\(whole(value, in: range))%"
    }

    /// `80 percent`, for VoiceOver.
    public static func spoken(_ value: Double, in range: ClosedRange<Double>) -> String {
        "\(whole(value, in: range)) percent"
    }

    private static func whole(_ value: Double, in range: ClosedRange<Double>) -> Int {
        let bounded =
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : range.lowerBound
        return Int(bounded.rounded())
    }
}
