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

    /// The legend uses the rows' own words (review UI-45).
    @Test func ringLegendRepeatsTheRowTitles() throws {
        let usage = Fixture.usage(.claude, Fixture.account("a"))
        let context = Fixture.context(
            Fixture.settings(), readings: [.claude: Fixture.current(usage)])
        guard case .accounts(let accounts) = PopoverModel(context).content else {
            Issue.record("Expected accounts")
            return
        }
        let legend = try #require(accounts.ringLegend)
        guard case .rings(let rings) = accounts.cards.first?.summary else {
            Issue.record("Expected rings")
            return
        }
        #expect(legend.outer == rings.outer.shortTitle)
        #expect(legend.inner == rings.inner.shortTitle)

        let bars = Fixture.context(
            Fixture.settings { $0.appearance.cardStyle = .bars },
            readings: [.claude: Fixture.current(usage)])
        guard case .accounts(let barAccounts) = PopoverModel(bars).content else {
            Issue.record("Expected accounts")
            return
        }
        #expect(barAccounts.ringLegend == nil)
    }

    @Test func thresholdTextIsAWholePercentInRange() {
        #expect(ThresholdText.percent(80, in: 50...90) == "80%")
        #expect(ThresholdText.percent(72.6, in: 50...90) == "73%")
        #expect(ThresholdText.percent(120, in: 50...90) == "90%")
        #expect(ThresholdText.percent(.nan, in: 50...90) == "50%")
        #expect(ThresholdText.spoken(95, in: 60...100) == "95 percent")
    }
}
