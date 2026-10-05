/// Strict decimal parsing for provider text. Rejects hex, exponents written as words, and
/// whitespace, which `Double(_:)` would accept in some forms.
public enum NumericText {
    public static func double(_ text: String) -> Double? {
        let pattern = /^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/
        guard text.wholeMatch(of: pattern) != nil, let value = Double(text), value.isFinite else {
            return nil
        }
        return value
    }
}
