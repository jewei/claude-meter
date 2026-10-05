import Foundation

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
