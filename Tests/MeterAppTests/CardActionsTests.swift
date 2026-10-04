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
