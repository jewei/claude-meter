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
        ("0.004", "<$0.01"), ("0.009", "<$0.01"), ("0.01", "$0.01"), ("42.105", "$42.11"),
        ("99.99", "$99.99"), ("99.996", "$100"), ("100", "$100"), ("1240.6", "$1,241"),
    ])
    func amountsFollowTheFormatBorders(cost: String, text: String) {
        let row = today(model(cost: cost))
        #expect(row?.value == text)
        #expect(row?.detail == "35.8M tokens")
        #expect(row?.isIncomplete == false)
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

    /// The `+` goes before a note that says why; the estimate note shows with any estimate.
    @Test func anIncompleteEstimateIsMarked() {
        let estimate = TokenRowsModel.FootnotePart.text("Estimated at API list prices, not a bill.")
        let unpriced = model(cost: "42", unpriced: 10, models: ["m"])
        #expect(today(unpriced)?.isIncomplete == true)
        #expect(unpriced?.footnote == [estimate, .mark, .text("No price for: m")])
        let partial = model(cost: "42", isPartial: true)
        #expect(today(partial)?.isIncomplete == true)
        #expect(
            partial?.footnote
                == [estimate, .mark, .text("Partial history — some records couldn't be counted")])
        // An old-data note does not explain the mark.
        let old = model(cost: "42", unpriced: 10, models: ["m"], observedAt: .reference(-1_000))
        #expect(today(old)?.isIncomplete == true)
        #expect(old?.footnote == [estimate, .text("Token data may be stale")])
        #expect(model(cost: "42")?.footnote == [estimate])
    }

    @Test func noPricedTokenShowsTheTokenCountOnly() {
        // Nothing is estimated, so the price note has no mark and no estimate note.
        let fixtures = [
            (model(), [TokenRowsModel.FootnotePart]()),
            (model(unpriced: 100, models: ["gpt-9"]), [.text("No price for: gpt-9")]),
        ]
        for (model, footnote) in fixtures {
            #expect(today(model)?.value == "35.8M")
            #expect(today(model)?.detail == "tokens")
            #expect(today(model)?.isIncomplete == false)
            #expect(model?.footnote == footnote)
        }
    }

    /// VoiceOver reads the footnote without the `+`: each tile says "may be higher".
    @Test func theSpokenFootnoteLeavesOutTheMark() {
        let model = model(cost: "42", unpriced: 10, models: ["m"])
        #expect(
            model?.spokenFootnote
                == "Estimated at API list prices, not a bill. No price for: m")
        #expect(self.model()?.spokenFootnote == "")
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
            model(cost: "1", unpriced: 100, models: ["m"], observedAt: .reference(-1_000))?.note
                == "Token data may be stale")
        #expect(
            model(cost: "1", unpriced: 100, models: ["m"], isPartial: true)?.note
                == "Partial history — some records couldn't be counted")
    }

    /// Cursor's and Grok's accounts report real money; their records carry no estimate.
    @Test(arguments: [ProviderID.cursor, .grok])
    func cursorAndGrokRowsAreUnchanged(provider: ProviderID) {
        #expect(today(model(provider))?.value == "35.8M")
        #expect(model(provider)?.note == nil)
        #expect(model(provider)?.footnote == [])
    }
}
