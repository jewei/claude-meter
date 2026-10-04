import MeterApp
import SwiftUI

extension GaugeModel {
    /// The display face for a number. An unknown value (`—`) uses the body face, because
    /// the display face draws the dash like a minus sign.
    @MainActor func valueFont(size: CGFloat) -> Font {
        hasValue ? MeterFont.display(size, .bold) : MeterFont.body(size - 1, .bold)
    }
}
