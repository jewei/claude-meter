import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

/// The extra-usage bar is the monthly budget as energy (review UI-07).
@Suite struct ExtraUsageCardTests {
    private func extra(
        used: Double?, amount: Decimal = 12.5, limit: Decimal? = 50, isPaused: Bool = false,
        configure: (inout Settings) -> Void = { _ in }
    ) -> ExtraUsageModel? {
        let windows = used.map {
            [Fixture.window(.billing, used: $0, resetsIn: nil, id: "extra-usage", isBinding: false)]
        }
        let account = Fixture.account(
            "claude", extra: windows ?? [],
            balances: [
                Balance(
                    kind: .extraUsage, amount: amount, limit: limit, unit: .currency("USD"),
                    isPaused: isPaused)
            ])
        let settings = Fixture.settings(configure: configure)
        let context = Fixture.context(
            settings, readings: [.claude: Fixture.current(Fixture.usage(.claude, account))])
        guard case .accounts(let model) = PopoverModel(context).content else { return nil }
        for card in model.cards {
            if case .extraUsage(let extra) = card.summary { return extra }
        }
        return nil
    }

    @Test func theBarDrainsAsMoneyIsSpent() throws {
        let model = try #require(extra(used: 25))
        #expect(model.fraction == 0.75)
        #expect(model.severity == .normal)
        #expect(model.shareText == "75% left")
        #expect(model.amountText == "$12.50 / $50.00")
        #expect(
            model.accessibilityValue == "$12.50 spent of $50.00, 75 percent left, full energy")
    }

    @Test func theLimitReadsAsEmptyAndRed() throws {
        let model = try #require(extra(used: 100, amount: 50))
        #expect(model.fraction == 0)
        #expect(model.severity == .exhausted)
        #expect(model.shareText == "0% left")
    }

    @Test func thresholdsColorTheSpentShare() throws {
        #expect(try #require(extra(used: 85)).severity == .warning)
        #expect(try #require(extra(used: 96)).severity == .critical)
        let strict = try #require(
            extra(used: 60) { $0.appearance.thresholds = Thresholds(warning: 50, critical: 60) })
        #expect(strict.severity == .critical)
    }

    @Test func usageModeFillsWithTheShareSpent() throws {
        let model = try #require(extra(used: 25) { $0.appearance.meterMode = .used })
        #expect(model.fraction == 0.25)
        #expect(model.shareText == "25% used")
        #expect(model.severity == .normal)
    }

    @Test func withoutAShareThereIsNoBar() throws {
        let model = try #require(extra(used: nil, limit: nil, isPaused: true))
        #expect(model.fraction == nil)
        #expect(model.shareText == nil)
        #expect(model.severity == .unknown)
        #expect(model.amountText == "$12.50")
        #expect(model.accessibilityValue == "$12.50 spent, paused")
    }
}
