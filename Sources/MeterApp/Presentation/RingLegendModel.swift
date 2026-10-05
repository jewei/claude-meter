import Foundation

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
