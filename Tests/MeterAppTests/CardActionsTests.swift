import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct CardActionsTests {
    private func accounts(
        claude: [AccountID] = ["home", "work"], codex: Bool = true, cursor: Bool = true,
        configure: (inout Settings) -> Void = { _ in }
    ) throws -> AccountsModel {
        var readings: [ProviderID: Reading<ProviderUsage>] = [:]
        var enabled: Set<ProviderID> = [.claude]
        let claudeAccounts = claude.enumerated().map { index, id in
            Fixture.account(id, session: Double(10 + index * 50))
        }
        readings[.claude] = Fixture.current(
            ProviderUsage(provider: .claude, accounts: claudeAccounts))
        if codex {
            enabled.insert(.codex)
            readings[.codex] = Fixture.current(Fixture.usage(.codex, Fixture.account("/codex")))
        }
        if cursor {
            enabled.insert(.cursor)
            readings[.cursor] = Fixture.current(Fixture.usage(.cursor, Fixture.account("cursor")))
        }
        let settings = Fixture.settings(enabled: enabled, configure: configure)
        let context = Fixture.context(settings, readings: readings)
        guard case .accounts(let model) = PopoverModel(context).content else {
            throw Failure.noAccounts
        }
        return model
    }

    private enum Failure: Error { case noAccounts }

    private func card(_ model: AccountsModel, _ id: CardID) throws -> CardModel {
        try #require(model.cards.first { $0.id == id })
    }

    /// Bar headers spoke `Cursor Cursor` (review UI-25).
    @Test func spokenTitleNamesTheProviderOnce() throws {
        let model = try accounts()
        #expect(try card(model, .account(.cursor, "cursor")).spokenTitle == "Cursor")
        #expect(try card(model, .account(.claude, "work")).spokenTitle == "Claude Work")
        #expect(try card(model, .account(.codex, "/codex")).spokenTitle == "Codex /codex")
    }

    @Test func headerValueStatesTheHeadlineAndTheDisclosure() throws {
        let model = try accounts { $0.appearance.cardStyle = .bars }
        guard case .bars(let bars) = try card(model, .account(.claude, "home")).summary else {
            Issue.record("Expected bars")
            return
        }
        #expect(
            bars.headerAccessibilityValue(isExpanded: false)
                == "\(bars.headline.accessibilityValue). Collapsed")
        #expect(bars.headerAccessibilityValue(isExpanded: true).hasSuffix(". Expanded"))
    }

    /// "Use in Menu Bar" selects the main meter without a drag.
    @Test func useInMenuBarIsOfferedForOtherClaudeAndCodexCards() throws {
        let model = try accounts()
        let main = try #require(model.cards.first)
        #expect(main.id == .account(.claude, "work"))
        #expect(!main.canUseInMenuBar)
        #expect(try card(model, .account(.claude, "home")).canUseInMenuBar)
        #expect(try card(model, .account(.codex, "/codex")).canUseInMenuBar)
        #expect(try !card(model, .account(.cursor, "cursor")).canUseInMenuBar)
    }

    /// VoiceOver gets "Move up" and "Move down" only where the move works (review UI-27).
    @Test func movesAreOfferedOnlyWhereTheyWork() throws {
        let model = try accounts(claude: ["home"], codex: false)
        let claude = CardID.account(.claude, "home")
        let cursor = CardID.account(.cursor, "cursor")
        #expect(model.cards.map(\.id) == [claude, cursor])
        #expect(!model.canMove(claude, by: -1))
        // Cursor can never go first while a Claude card is visible.
        #expect(!model.canMove(claude, by: 1))
        #expect(!model.canMove(cursor, by: -1))
        #expect(!model.canMove(cursor, by: 1))
        #expect(!model.canMove(.extraUsage, by: 1))

        let full = try accounts()
        let ids = full.cards.map(\.id)
        // The main card stays first; another card takes its place by moving up.
        #expect(!full.canMove(ids[0], by: 1))
        #expect(full.canMove(ids[1], by: -1))
        #expect(full.canMove(ids[1], by: 1))
        #expect(!full.canMove(try #require(ids.last), by: 1))
        #expect(!full.canMove(ids[1], by: 0))
    }

    /// A drag shows the new order before the drop. Back in its own place, the card changes
    /// nothing (review R3-U-03).
    @Test func aDragPreviewShowsTheNewOrderOnlyWhileTheCardIsMoved() throws {
        let model = try accounts()
        let ids = model.cards.map(\.id)
        let codex = CardID.account(.codex, "/codex")
        let from = try #require(ids.firstIndex(of: codex))

        let top = try #require(model.dragPreview(moving: codex, to: 0))
        #expect(top.index == 0)
        #expect(top.order == [codex] + ids.filter { $0 != codex })
        #expect(model.cards(during: top).map(\.id) == top.order)

        let back = try #require(model.dragPreview(moving: codex, to: from))
        #expect(back.order == ids)
        #expect(model.cards(during: back) == model.cards)
    }

    /// A first card that is not the main card becomes the main meter in its own place: its
    /// drag starts with an accepted preview, so a drop in place pins it (review R4-A-04).
    @Test func aDragOfAFirstCardThatIsNotMainCanPinItInPlace() throws {
        // Claude is in use with no account, so the Codex card is first without being main.
        let model = try accounts(claude: [])
        let ids = model.cards.map(\.id)
        let codex = CardID.account(.codex, "/codex")
        #expect(ids.first == codex)
        let mainCards = model.cards.filter(\.isMain)
        #expect(mainCards.isEmpty)

        let start = try #require(model.dragPreview(moving: codex, to: nil, after: nil))
        #expect(start.index == 0)
        #expect(start.order == ids)
        #expect(model.accepts(start))
    }

    /// Any other card starts its drag in its own place with no change: the drop there saves
    /// nothing.
    @Test func aDragStartsInTheCardsOwnPlace() throws {
        let model = try accounts()
        let ids = model.cards.map(\.id)
        let main = try #require(ids.first)
        let codex = CardID.account(.codex, "/codex")
        let from = try #require(ids.firstIndex(of: codex))
        for card in [main, codex] {
            let start = try #require(model.dragPreview(moving: card, to: nil, after: nil))
            #expect(start.index == ids.firstIndex(of: card))
            #expect(start.order == ids)
            #expect(model.cards(during: start) == model.cards)
        }
        #expect(model.dragPreview(moving: .account(.grok, .default), to: nil, after: nil) == nil)

        // The pointer reaches the top, stays, then tries a place that the drop refuses.
        let top = try #require(model.dragPreview(moving: codex, to: 0, after: nil))
        #expect(model.dragPreview(moving: codex, to: nil, after: top) == top)
        #expect(model.dragPreview(moving: codex, to: ids.count, after: top) == top)
        // Back in its own place, the card changes nothing again.
        let back = try #require(model.dragPreview(moving: codex, to: from, after: top))
        #expect(back.order == ids)
        // A preview of another card does not carry over.
        let other = try #require(model.dragPreview(moving: codex, to: nil, after: nil))
        #expect(model.dragPreview(moving: main, to: nil, after: other)?.card == main)
    }

    /// The preview never shows a place that the drop refuses, so the drop always applies.
    @Test func aDragPreviewSkipsPlacesThatTheDropRefuses() throws {
        let model = try accounts()
        let ids = model.cards.map(\.id)
        // Cursor never goes first while a Claude card shows, and the main card stays first.
        #expect(model.dragPreview(moving: .account(.cursor, "cursor"), to: 0) == nil)
        #expect(model.dragPreview(moving: ids[0], to: 1) == nil)
        #expect(model.dragPreview(moving: ids[1], to: ids.count) == nil)
        #expect(model.dragPreview(moving: ids[1], to: -1) == nil)
        #expect(model.dragPreview(moving: .account(.grok, .default), to: 1) == nil)
        // A move lower in the list keeps the main card first.
        let lower = try #require(model.dragPreview(moving: ids[1], to: ids.count - 1))
        #expect(lower.order.first == ids[0])
    }

    /// A refresh that changes the cards during a drag ends the preview: the list shows the
    /// cards in their own order, and the drop does nothing.
    @Test func aPreviewThatNoLongerFitsTheCardsIsIgnored() throws {
        let full = try accounts()
        let preview = try #require(full.dragPreview(moving: .account(.codex, "/codex"), to: 1))
        #expect(full.accepts(preview))
        let fewer = try accounts(cursor: false)
        #expect(!fewer.accepts(preview))
        #expect(fewer.cards(during: preview) == fewer.cards)
        #expect(fewer.cards(during: nil) == fewer.cards)
    }

    @Test func announcementsSayWhereTheCardWent() throws {
        let model = try accounts()
        let codex = try card(model, .account(.codex, "/codex"))
        #expect(
            model.moveAnnouncement(codex, to: 0)
                == "Codex /codex is first and shows in the menu bar.")
        #expect(
            model.moveAnnouncement(codex, to: 1)
                == "Codex /codex moved to position 2 of \(model.cards.count).")
    }
}
