import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

/// Pace on cards: the text and the even-pace mark (`docs/product.md`, Pace).
@Suite struct PaceCardTests {
    /// A 5-hour session, 2 hours in, that resets in 3 hours. 50% used runs out in 2 hours.
    private func session(used: Double) -> QuotaWindow {
        Fixture.window(.session, used: used, resetsIn: .hours(3), duration: .hours(5))
    }

    private func account(_ windows: [QuotaWindow]) -> AccountUsage {
        AccountUsage(id: "work", name: "Work", windows: windows, observedAt: .reference())
    }

    private func cards(
        _ readings: [ProviderID: Reading<ProviderUsage>], enabled: Set<ProviderID> = [.claude],
        configure: (inout Settings) -> Void = { _ in }
    ) -> [CardModel] {
        let settings = Fixture.settings(enabled: enabled, configure: configure)
        let context = Fixture.context(settings, readings: readings)
        guard case .accounts(let model) = PopoverModel(context).content else { return [] }
        return model.cards
    }

    private func rings(_ reading: Reading<ProviderUsage>, showsUsed: Bool = false) -> RingsModel? {
        let cards = cards([.claude: reading]) {
            $0.appearance.meterMode = showsUsed ? .used : .energyLeft
        }
        guard case .rings(let rings) = cards.first?.summary else { return nil }
        return rings
    }

    @Test func ringRowsShowPaceAndMark() throws {
        let usage = Fixture.usage(.claude, account([session(used: 50)]))
        let rings = try #require(rings(Fixture.current(usage)))
        #expect(rings.inner.paceText == "Runs out in 2h")
        // A run-out before the reset needs attention even while energy is full. The fill
        // (50% left) is short of the mark (60%).
        #expect(rings.inner.paceSeverity == .warning)
        #expect(rings.inner.shortfallSeverity == .warning)
        #expect(rings.inner.accessibilityValue.hasSuffix("runs out in 2h"))
        // 2 of 5 hours: an even pace has used 40%, so 60% is left.
        #expect(try abs(#require(rings.inner.evenPaceFraction) - 0.6) < 1e-9)
        // The weekly window has no duration, so it has no pace.
        #expect(rings.outer.paceText == nil)
        #expect(rings.outer.evenPaceFraction == nil)
    }

    @Test func theMarkFollowsTheMeterMode() throws {
        let usage = Fixture.usage(.claude, account([session(used: 50)]))
        let rings = try #require(rings(Fixture.current(usage), showsUsed: true))
        #expect(try abs(#require(rings.inner.evenPaceFraction) - 0.4) < 1e-9)
        // In Usage mode the fill passes the mark; there is no shortfall to hatch.
        #expect(rings.inner.paceSeverity == .warning)
        #expect(rings.inner.shortfallSeverity == nil)
    }

    @Test func aStaleAccountHasNoPace() throws {
        let usage = Fixture.usage(.claude, account([session(used: 50)]))
        let stale = Reading<ProviderUsage>.stale(
            usage, observedAt: .reference(), issue: UsageIssue("Offline"))
        let rings = try #require(rings(stale))
        #expect(rings.inner.paceText == nil)
        #expect(rings.inner.evenPaceFraction == nil)
    }

    /// A non-binding scoped window shows its pace on the card. The hero does not name it
    /// (``HeroModelTests``).
    @Test func aScopedWindowShowsItsPace() throws {
        let sonnet = Fixture.window(
            .scoped, used: 80, resetsIn: .days(3), id: "seven_day_sonnet", title: "Sonnet Weekly",
            isBinding: false, duration: .days(7))
        let usage = Fixture.usage(.claude, account([session(used: 10), sonnet]))
        let rings = try #require(rings(Fixture.current(usage)))
        #expect(rings.rows.last?.paceText == "Runs out in 24h")
    }

    /// A window that is already critical keeps its own severity for the run-out; a tight
    /// verdict shows without one.
    @Test func paceSeverityFollowsTheVerdictAndTheWindow() throws {
        // 2 of 5 hours in: 96% used (critical from 95%) runs out in 5 minutes.
        let critical = try #require(
            rings(Fixture.current(Fixture.usage(.claude, account([session(used: 96)]))))
        ).inner
        #expect(critical.severity == .critical)
        #expect(critical.paceSeverity == .critical)
        // 36% used projects 90% at the reset: 10% spare is tight.
        let tight = try #require(
            rings(Fixture.current(Fixture.usage(.claude, account([session(used: 36)]))))
        ).inner
        #expect(tight.paceText == "Tight: ~10% left at reset")
        #expect(tight.paceSeverity == nil)
        #expect(tight.shortfallSeverity == nil)
    }

    /// The mark moves with the clock; the projection stays with the observation. 10 minutes
    /// after a reading of 48% used, 2h 20m into a 5-hour session (46.7% at an even pace), it
    /// still runs out, but an even pace has now used 50%: in Usage mode the mark is beyond
    /// the fill, on the part that is under pace, and in Energy left mode the mark is back on
    /// the fill.
    @Test func theShortfallIsOnlyInEnergyLeftModeAndBeyondTheFill() throws {
        let window = Fixture.window(
            .session, used: 48, resetsIn: .hours(2.5), duration: .hours(5))
        let account = AccountUsage(
            id: "work", name: "Work", windows: [window],
            observedAt: .reference(-.minutes(10)))
        let reading = Fixture.current(Fixture.usage(.claude, account))
        let used = try #require(rings(reading, showsUsed: true)).inner
        #expect(used.paceText?.hasPrefix("Runs out") == true)
        #expect(try #require(used.evenPaceFraction) > used.fraction)
        #expect(used.shortfallSeverity == nil)
        let left = try #require(rings(reading)).inner
        #expect(left.paceSeverity == .warning)
        #expect(try #require(left.evenPaceFraction) < left.fraction)
        #expect(left.shortfallSeverity == nil)
    }

    @Test func cursorBillingShowsPaceWithoutBarLabels() throws {
        let cursor = AccountUsage(
            id: .default, name: "Cursor",
            windows: [
                Fixture.window(
                    .billing, used: 20, resetsIn: .days(20), title: "Billing period",
                    duration: .days(30)),
                Fixture.window(
                    .scoped, used: 10, resetsIn: .days(20), title: "API", isBinding: false),
            ],
            observedAt: .reference())
        let claude = Fixture.usage(.claude, Fixture.account("a"))
        let all = cards(
            [
                .claude: Fixture.current(claude),
                .cursor: Fixture.current(.init(provider: .cursor, accounts: [cursor])),
            ],
            enabled: [.claude, .cursor]
        ) { $0.cards.expanded = [.account(.cursor, .default)] }
        let card = try #require(all.last)
        guard case .bars(let bars) = card.summary else {
            Issue.record("Expected bars")
            return
        }
        #expect(!bars.showsBarLabels)
        // 20% in 10 of 30 days: 40% more in the last 20 days leaves 40%. Only the mark and
        // the spoken value say so.
        #expect(bars.headline.paceText == nil)
        #expect(bars.headline.paceSeverity == nil)
        #expect(bars.headline.shortfallSeverity == nil)
        #expect(bars.headline.evenPaceFraction != nil)
        #expect(bars.headline.accessibilityValue.hasSuffix("lasts until reset"))
        guard case .usageBars(let rows)? = card.details.first else {
            Issue.record("Expected usage rows")
            return
        }
        #expect(rows.allSatisfy { $0.paceText == nil })
    }
}
