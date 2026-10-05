import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct GaugeTextTests {
    private func gauge(used: Double?, showsUsed: Bool = false) -> GaugeModel {
        let settings = Fixture.settings {
            $0.appearance.meterMode = showsUsed ? .used : .energyLeft
        }
        let context = Fixture.context(settings, readings: [:])
        return GaugeBuilder(context: context).gauge(
            Fixture.window(.session, used: used), title: "Session", shortTitle: "5-hr")
    }

    /// Bar labels and usage rows say whether the number is left or used (review UI-26,
    /// UI-39).
    @Test func valueTextsSayLeftOrUsed() {
        #expect(gauge(used: 40).valueWithCaption == "60% left")
        #expect(gauge(used: 40, showsUsed: true).valueWithCaption == "40% used")
        #expect(gauge(used: 40).summaryText == "Session · 60% left")
        #expect(gauge(used: nil).valueWithCaption == "—")
        #expect(gauge(used: nil).summaryText == "Session · —")
    }

    @Test func unknownValuesAreMarked() {
        #expect(gauge(used: 0).hasValue)
        #expect(!gauge(used: nil).hasValue)
    }
}
