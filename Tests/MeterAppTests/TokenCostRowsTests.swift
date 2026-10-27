import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

/// Cost estimates on the token rows (`docs/product.md` §5, `docs/design.md`).
@Suite struct TokenCostRowsTests {
    private let calendar = Calendar.fixed()

    private func model(
        _ provider: ProviderID = .claude, cost: String? = nil, unpriced: Int64 = 0,
        models: Set<String> = [], isPartial: Bool = false, observedAt: Date = .reference()
    ) -> TokenRowsModel? {
        let today = calendar.startOfDay(for: .reference())
        let account = TokenHistory(
            dailyTokens: [today: 35_800_000], coverageStart: today.addingTimeInterval(-.days(6)),
            observedAt: observedAt, timeZoneID: calendar.timeZone.identifier,
            isPartial: isPartial,
            dailyCost: cost.map { [today: Decimal(string: $0) ?? 0] } ?? [:],
            dailyUnpricedTokens: unpriced > 0 ? [today: unpriced] : [:], unpricedModels: models)
        let history = ProviderTokenHistory(
            provider: provider, source: provider == .cursor ? .account : .thisMac,
            accounts: ["a": account], coverageStart: account.coverageStart,
            observedAt: observedAt, timeZoneID: calendar.timeZone.identifier)
        let settings = Fixture.settings(enabled: [.claude, .cursor, .grok])
        let context = PresentationContext(
            settings: settings, histories: [provider: .current(history, observedAt: observedAt)],
            now: .reference(), calendar: calendar)
        return TokenRowsBuilder(context: context).model(provider: provider, account: "a")
    }

    private func today(_ model: TokenRowsModel?) -> TokenRowsModel.Row? {
        model?.rows.first
    }

    @Test(arguments: [
        ("0.004", "35.8M tokens · <$0.01"), ("0.009", "35.8M tokens · <$0.01"),
        ("0.01", "35.8M tokens · ~$0.01"),
        ("42.105", "35.8M tokens · ~$42.11"), ("99.99", "35.8M tokens · ~$99.99"),
        ("99.996", "35.8M tokens · ~$100"), ("100", "35.8M tokens · ~$100"),
        ("1240.6", "35.8M tokens · ~$1,241"),
    ])
    func amountsFollowTheFormatBorders(cost: String, text: String) {
        #expect(today(model(cost: cost))?.value == text)
    }

    @Test func helpAndSpeechSayItIsAnEstimate() {
        let row = today(model(cost: "42.4"))
        #expect(row?.help.hasSuffix("Estimated at API list prices. Not a bill.") == true)
        #expect(row?.accessibilityValue == "35800000 tokens, about 42 dollars at API prices")
        let small = today(model(cost: "0.5", unpriced: 10, models: ["m"]))
        #expect(
            small?.accessibilityValue.hasSuffix(
                "about 50 cents at API prices, may be higher") == true)
        // The speech follows the amount that the row shows.
        #expect(
            today(model(cost: "0.996"))?.accessibilityValue.hasSuffix(
                "about 1 dollar at API prices") == true)
        #expect(
            today(model(cost: "0.004"))?.accessibilityValue.hasSuffix(
                "under 1 cent at API prices") == true)
    }

    @Test func anIncompleteEstimateIsMarked() {
        #expect(today(model(cost: "42", unpriced: 10, models: ["m"]))?.value.hasSuffix("+") == true)
        #expect(today(model(cost: "42", isPartial: true))?.value.hasSuffix("+") == true)
    }

    @Test func noPricedTokenShowsTheTokenCountOnly() {
        #expect(today(model())?.value == "35.8M tokens")
        #expect(today(model(unpriced: 100, models: ["gpt-9"]))?.value == "35.8M tokens")
    }

    /// The price note also shows when no row has an estimate, so a new model explains it.
    @Test func thePriceNoteNamesModelsThroughTheRedactor() {
        #expect(model(unpriced: 100, models: ["gpt-9"])?.note == "No price for: gpt-9")
        let many = model(cost: "1", unpriced: 100, models: ["a", "b", "c", "d", "e"])
        #expect(many?.note == "No price for: a, b, c and 2 more")
        let email = model(unpriced: 100, models: ["me@example.com"])?.note
        #expect(email?.contains("example.com") == false)
        #expect(model(cost: "1", unpriced: 100)?.note == "Some tokens have no price")
        #expect(model(cost: "1")?.note == nil)
    }

    /// The old-data and partial notes come first.
    @Test func olderNotesWin() {
        #expect(
            model(cost: "1", unpriced: 100, models: ["m"], observedAt: .reference(-700))?.note
                == "Token data may be stale")
        #expect(
            model(cost: "1", unpriced: 100, models: ["m"], isPartial: true)?.note
                == "Partial history · some records could not be counted")
    }

    /// Cursor's and Grok's accounts report real money; their records carry no estimate.
    @Test(arguments: [ProviderID.cursor, .grok])
    func cursorAndGrokRowsAreUnchanged(provider: ProviderID) {
        #expect(today(model(provider))?.value == "35.8M tokens")
        #expect(model(provider)?.note == nil)
    }
}
