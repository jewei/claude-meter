import SwiftUI

/// Fixed widths for changing numbers set in Fredoka.
///
/// Fredoka has no tabular digits, so `.monospacedDigit()` does nothing on it: a new value
/// would change the width of its text and move what is next to it. A number in Fredoka
/// takes the width of the widest text that it can show instead
/// (``SwiftUI/View/fixedNumberWidth(fitting:font:alignment:)``).
@MainActor enum FixedNumberWidth {
    /// The widest whole percentage: its third digit is wider than any difference between two
    /// digits, so no value from `0%` to `99%` is wider (`DesignSystemTests` checks each).
    static let percent = "100%"

    /// `text` with every digit replaced by the widest digit of the display face: the widest
    /// text with as many digits, for a number that has no widest value, such as an amount.
    static func template(_ text: String, weight: MeterFont.DisplayWeight) -> String {
        let widest = MeterFont.widestDigit(weight)
        return String(text.map { $0.isASCII && $0.isNumber ? widest : $0 })
    }
}

extension View {
    /// Gives a changing number the width of `widest` set in `font`, and places it at
    /// `alignment` in that width, so a new value never moves the views beside it. A wider
    /// value still shows in full: the number never truncates.
    func fixedNumberWidth(
        fitting widest: String, font: Font, alignment: Alignment = .trailing
    ) -> some View {
        ZStack(alignment: alignment) {
            Text(widest).font(font).hidden().accessibilityHidden(true)
            self
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
