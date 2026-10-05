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
