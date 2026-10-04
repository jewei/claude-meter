import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct CardOrderTests {
    @Test func savedOrderThenAutomaticThenMainFirst() {
        let automatic: [CardID] = [
            .account(.claude, "work"), .account(.claude, "personal"), .account(.codex, "home"),
            .account(.cursor, .default),
        ]
        let saved: [CardID] = [
            .account(.cursor, .default), .account(.grok, .default), .account(.claude, "personal"),
            .account(.cursor, .default),
        ]
        #expect(
            CardOrder.ordered(automatic: automatic, saved: saved, main: nil) == [
                .account(.cursor, .default), .account(.claude, "personal"),
                .account(.claude, "work"), .account(.codex, "home"),
            ])
        #expect(
            CardOrder.ordered(automatic: automatic, saved: saved, main: .account(.codex, "home"))
                == [
                    .account(.codex, "home"), .account(.cursor, .default),
                    .account(.claude, "personal"), .account(.claude, "work"),
                ])
    }

    @Test func movingAnAccountToTheTopMakesItTheMainMeter() {
        let visible: [CardID] = [.account(.claude, "a"), .account(.codex, "b"), .extraUsage]
        let move = CardOrder.move(
            .account(.codex, "b"), to: 0, visible: visible, saved: [.account(.grok, .default)],
            main: .account(.claude, "a"))
        #expect(
            move?.order == [
                .account(.codex, "b"), .account(.claude, "a"), .extraUsage,
                .account(.grok, .default),
            ])
        #expect(move?.newMain == .account(.codex, "b"))
    }

    @Test func movesBelowTheTopKeepTheMainMeter() {
        let visible: [CardID] = [.account(.claude, "a"), .account(.codex, "b"), .extraUsage]
        let move = CardOrder.move(
            .extraUsage, to: 1, visible: visible, saved: [], main: .account(.claude, "a"))
        #expect(move?.order == [.account(.claude, "a"), .extraUsage, .account(.codex, "b")])
        #expect(move?.newMain == nil)
    }

    @Test func refusesCardsThatCannotOwnTheMenuBar() {
        let visible: [CardID] = [.account(.claude, "a"), .account(.cursor, .default), .extraUsage]
        for card in [CardID.account(.cursor, .default), .extraUsage] {
            #expect(CardOrder.move(card, to: 0, visible: visible, saved: [], main: nil) == nil)
        }
        #expect(
            CardOrder.move(.account(.claude, "a"), to: 0, visible: visible, saved: [], main: nil)
                == nil)
    }
}

@Suite struct CardBuilderTests {
    private func cards(
        _ readings: [ProviderID: Reading<ProviderUsage>], enabled: Set<ProviderID>,
        configure: (inout Settings) -> Void = { _ in }
    ) -> [CardModel] {
        let settings = Fixture.settings(enabled: enabled, configure: configure)
        let context = Fixture.context(settings, readings: readings)
        guard case .accounts(let model) = PopoverModel(context).content else { return [] }
        return model.cards
    }

    @Test func mainAccountComesFirstThenExtraUsageThenOthers() {
        let claude = Fixture.usage(
            .claude, Fixture.account("home", session: 10),
            Fixture.account(
                "work", session: 90,
                extra: [Fixture.window(.billing, used: 30, id: "extra-usage", isBinding: false)],
                balances: [
                    Balance(kind: .extraUsage, amount: 12.34, limit: 50, unit: .currency("USD"))
                ]))
        let codex = Fixture.usage(.codex, Fixture.account("/codex"))
        let cards = cards(
            [.claude: Fixture.current(claude), .codex: Fixture.current(codex)],
            enabled: [.claude, .codex])
        #expect(
            cards.map(\.id) == [
                .account(.claude, "work"), .account(.claude, "home"), .extraUsage,
                .account(.codex, "/codex"),
            ])
        #expect(cards[0].isMain)
        guard case .extraUsage(let extra) = cards[2].summary else {
            Issue.record("Expected an extra usage card")
            return
        }
        #expect(extra.amountText == "$12.34 / $50.00")
        #expect(extra.fraction == 0.3)
    }

    @Test func ringCardsShowEveryWindow() throws {
        let opus = Fixture.window(.scoped, used: 40, id: "seven_day_opus")
        let usage = Fixture.usage(
            .claude, Fixture.account("a", session: 25, weekly: 50, extra: [opus]))
        let card = try #require(cards([.claude: Fixture.current(usage)], enabled: [.claude]).first)
        guard case .rings(let rings) = card.summary else {
            Issue.record("Expected rings")
            return
        }
        #expect(rings.rows.map(\.shortTitle) == ["5-hr", "week", "opus"])
        #expect(rings.inner.valueText == "75%")
        #expect(rings.inner.caption == "left")
        #expect(rings.outer.fraction == 0.5)
        #expect(rings.initial == "A")
        #expect(card.disclosure == .alwaysOpen)
    }

    @Test func barCardsCollapseAndKeepOneUnknownBar() throws {
        let usage = Fixture.usage(.codex, Fixture.account("/h", session: nil, weekly: nil))
        let card = try #require(
            cards(
                [.codex: Fixture.current(usage)], enabled: [.codex],
                configure: {
                    $0.menuBar.provider = .codex
                    $0.appearance.cardStyle = .bars
                }
            ).first)
        guard case .bars(let bars) = card.summary else {
            Issue.record("Expected bars")
            return
        }
        #expect(bars.bars.map(\.title) == ["Session"])
        #expect(bars.headline.valueText == "—")
        #expect(card.disclosure == .collapsed)
        #expect(card.details.contains(.resets(ResetsBuilder.model(nil, now: .reference()))))
    }

    @Test func cursorCaptionShowsSpendAndReset() throws {
        let cursor = AccountUsage(
            id: .default, name: "Cursor", plan: "Pro",
            windows: [
                Fixture.window(.billing, used: 42, resetsIn: .hours(2), title: "Total"),
                Fixture.window(.scoped, used: 10, title: "Auto", isBinding: false),
            ],
            balances: [Balance(kind: .spend, amount: 120.25, limit: 400, unit: .currency("USD"))],
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
        #expect(bars.caption == "$120.25 spent · Resets in 2h")
        #expect(card.plan == PlanBadge(plan: "Pro", verbatim: true))
        #expect(card.disclosure == .expanded)
        #expect(card.details.contains { if case .usageBars = $0 { true } else { false } })
    }

    @Test func otherProvidersStateTheirFailures() throws {
        let claude = Fixture.usage(.claude, Fixture.account("a"))
        let codex = Fixture.usage(.codex, Fixture.account("/h"))
        let all = cards(
            [
                .claude: Fixture.current(claude),
                .codex: .stale(codex, observedAt: .reference(), issue: UsageIssue("Offline")),
            ], enabled: [.claude, .codex])
        #expect(
            all.last?.status
                == StatusLine(text: "Refresh failed · showing last known data", isFailure: true))
        #expect(all.first?.status == nil)
    }

    @Test func accountIssuesShowWithARetryCountdown() throws {
        let issue = UsageIssue("Rate limited.", retryAt: .reference(.minutes(3)))
        let usage = Fixture.usage(.claude, Fixture.account("a", issue: issue))
        let card = try #require(cards([.claude: Fixture.current(usage)], enabled: [.claude]).first)
        #expect(card.status == StatusLine(text: "Rate limited. Retrying in 3m.", isFailure: true))
    }

    @Test func planBadges() {
        #expect(PlanBadge(plan: "Max 20x") == PlanBadge(plan: "MAX 20X", verbatim: true))
        #expect(PlanBadge(plan: "Max 20x")?.tier == .max)
        #expect(PlanBadge(plan: "Claude Max")?.text == "MAX")
        #expect(PlanBadge(plan: "Team")?.tier == .pro)
        #expect(PlanBadge(plan: "free")?.text == "FREE")
        #expect(PlanBadge(plan: "Plus", verbatim: true)?.text == "PLUS")
        #expect(PlanBadge(plan: "  ") == nil)
    }
}

@Suite struct DetailBuilderTests {
    @Test func resetsListDetailsAndExplainMissingOnes() {
        let allowance = ResetAllowance(
            available: 3,
            resets: [
                .init(title: "Reset", expiresAt: .reference(.days(2))),
                .init(title: "Bonus", expiresAt: nil),
            ])
        let model = ResetsBuilder.model(allowance, now: .reference())
        #expect(model.countText == "3 available")
        #expect(model.rows.map(\.expiryText) == ["Expires in 2d", "Expiry date not provided"])
        #expect(model.note == "Expiry details shown for 2 of 3 resets")
        #expect(model.summary == "3 usage resets available")
        #expect(ResetsBuilder.model(nil, now: .reference()).countText == "Not reported")
        #expect(
            ResetsBuilder.model(.init(available: 1), now: .reference()).note
                == "Expiry details unavailable")
    }

    @Test func tokenRowsFormatCountsAndNotes() throws {
        let calendar = Calendar.fixed()
        let today = calendar.startOfDay(for: .reference())
        let history = TokenHistory(
            dailyTokens: [today: 35_800_000], coverageStart: today.addingTimeInterval(-.days(6)),
            observedAt: .reference(), timeZoneID: calendar.timeZone.identifier, isPartial: true)
        let provider = ProviderTokenHistory(
            provider: .claude, source: .thisMac, accounts: ["a": history],
            coverageStart: history.coverageStart, observedAt: .reference(),
            timeZoneID: calendar.timeZone.identifier)
        var context = Fixture.context(Fixture.settings(), readings: [:])
        context.histories = [.claude: .current(provider, observedAt: .reference())]
        let model = try #require(
            TokenRowsBuilder(context: context).model(provider: .claude, account: "a"))
        #expect(model.rows.first?.value == "35.8M tokens")
        #expect(model.sourceLabel == "This Mac")
        #expect(model.note == "Partial history · some records could not be counted")
        let other = try #require(
            TokenRowsBuilder(context: context).model(provider: .claude, account: "b"))
        #expect(other.rows.first?.value == "—")
        #expect(other.note == "No local token records")
    }
}
