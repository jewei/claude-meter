import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct RingLegendModelTests {
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

    @Test func ringLegendNeedsARingCard() {
        let cursor = Fixture.current(Fixture.usage(.cursor, Fixture.account(.default)))
        let context = Fixture.context(
            Fixture.settings(enabled: [.cursor]), readings: [.cursor: cursor])
        guard case .accounts(let accounts) = PopoverModel(context).content else {
            Issue.record("Expected accounts")
            return
        }
        #expect(accounts.ringLegend == nil)
    }
}
