import AppKit
import MeterDomain
import SwiftUI
import Testing

@testable import MeterApp
@testable import MeterUI

/// Fredoka has no tabular digits, so each changing number set in it takes a fixed width
/// (review R5-U-01). Each check lays out the view that the app shows for every value.
@MainActor @Suite struct FixedNumberWidthTests {
    init() {
        MeterFont.registerBundledFonts()
    }

    private func width(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    private func gauge(_ value: String, hasValue: Bool = true) -> GaugeModel {
        GaugeModel(
            title: "Session", shortTitle: "5-hr", valueText: value,
            caption: hasValue ? "left" : nil, fraction: 0.5, severity: .normal,
            resetText: nil, accessibilityValue: value)
    }

    @Test func gaugeValuesKeepOneWidth() {
        // Without a fixed width, Fredoka values differ in width.
        let plain = ["10%", "88%"].map { width(Text($0).font(MeterFont.display(14, .bold))) }
        #expect(plain[0] < plain[1])
        for size: CGFloat in [12, 14] {
            let values = (0...100).map { gauge("\($0)%") } + [gauge("—", hasValue: false)]
            let widths = Set(
                values.map { width(GaugeValueText(gauge: $0, size: size, color: Palette.ink)) })
            #expect(widths.count == 1, "\(size) pt: \(widths.sorted())")
        }
    }

    @Test func thresholdPillsKeepOneWidth() {
        var widths: Set<CGFloat> = []
        for range in [Thresholds.warningRange, Thresholds.criticalRange] {
            for value in stride(from: range.lowerBound, through: range.upperBound, by: 5) {
                let row = ThresholdRow(
                    label: "Warning", color: Palette.energyLow, ink: Palette.energyLowInk,
                    value: .constant(value), range: range, step: 5)
                widths.insert(width(row.pill))
            }
        }
        #expect(widths.count == 1, "\(widths.sorted())")
    }

    /// An amount has no widest value: it keeps one width while it has as many digits.
    @Test func extraUsageAmountsKeepOneWidthPerDigitCount() {
        func amountWidth(_ text: String) -> CGFloat {
            let extra = ExtraUsageModel(
                amountText: text, isPaused: false, fraction: nil, severity: .normal,
                shareText: nil, accessibilityValue: text)
            let card = CardModel(
                id: .extraUsage, provider: .claude, title: "Extra usage", plan: nil,
                sharesLogin: false, isMain: false, disclosure: .alwaysOpen,
                summary: .extraUsage(extra), details: [], status: nil)
            return width(ExtraUsageCardView(card: card, extra: extra).amount)
        }
        let amounts = ["$10.00 / $50.00", "$11.11 / $50.00", "$47.38 / $50.00", "$99.99 / $50.00"]
        let widths = Set(amounts.map(amountWidth))
        #expect(widths.count == 1, "\(widths.sorted())")
        let template = FixedNumberWidth.template("$12.50 / $50.00", weight: .bold)
        #expect(template.filter { !$0.isNumber } == "$. / $.")
        #expect(Set(template.filter(\.isNumber)) == [MeterFont.widestDigit(.bold)])
    }
}
