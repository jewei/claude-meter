import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct HeroModelTests {
    private func hero(
        _ accounts: [AccountUsage], pin: AccountID? = nil, now: Date = .reference(),
        configure: (inout Settings) -> Void = { _ in }
    ) -> HeroModel {
        let settings = Fixture.settings {
            $0.menuBar.pinnedAccounts[.claude] = pin
            configure(&$0)
        }
        let usage = ProviderUsage(provider: .claude, accounts: accounts)
        let context = Fixture.context(
            settings, readings: [.claude: Fixture.current(usage)], now: now)
        return HeroModel(MainMeter(context), context: context)
    }

    private func single(session: Double, resetsIn: TimeInterval = .minutes(10)) -> AccountUsage {
        AccountUsage(
            id: "work", name: "Work",
            windows: [
                Fixture.window(.session, used: session, resetsIn: resetsIn),
                Fixture.window(.weekly, used: 1, resetsIn: .days(3)),
            ],
            observedAt: .reference())
    }

    @Test func oneAccountNamesItsLimitingWindow() {
        let hero = hero([single(session: 99)])
        #expect(hero.title == "Almost tapped out")
        #expect(hero.subtitle == "Almost dry · Session resets in 10m")
        #expect(hero.tone == .empty)
    }

    @Test func exhaustedAccountTakesABreather() {
        for used in [100.0, 105] {
            let hero = hero([single(session: used)])
            #expect(hero.emoji == "🥵")
            #expect(hero.title == "Take a breather")
            #expect(hero.subtitle == "Out of energy · Session resets in 10m")
        }
    }

    @Test func healthyAccountCelebratesWithoutAReset() {
        let account = AccountUsage(
            id: "a", name: "A", windows: [Fixture.window(.session, used: 5, resetsIn: nil)],
            observedAt: .reference())
        let hero = hero([account])
        #expect(hero.title == "You're cruising")
        #expect(hero.subtitle == "Plenty in the tank 🎉")
    }

    @Test func limitingResetIgnoresAnEarlierResetOfAnotherWindow() {
        let account = AccountUsage(
            id: "a", name: "A",
            windows: [
                Fixture.window(.session, used: 10, resetsIn: .minutes(5)),
                Fixture.window(.weekly, used: 85, resetsIn: .hours(30)),
            ],
            observedAt: .reference())
        #expect(hero([account]).subtitle == "Getting low · Weekly resets in 30h")
    }

    @Test func equalUsagePicksTheLaterReset() {
        let account = AccountUsage(
            id: "a", name: "A",
            windows: [
                Fixture.window(.session, used: 85, resetsIn: .minutes(5)),
                Fixture.window(.weekly, used: 85, resetsIn: .hours(30)),
            ],
            observedAt: .reference())
        #expect(HeroModel.limitingReset(account, now: .reference()) == "Weekly resets in 30h")
    }

    @Test func severalAccountsCountTheFreshOnes() {
        let full = AccountUsage(
            id: "home", name: "Home", windows: [Fixture.window(.session, used: 5)],
            observedAt: .reference())
        let hero = hero([full, single(session: 99)], pin: "home")
        #expect(hero.title == "You're cruising")
        #expect(hero.subtitle == "1 fresh · Work nearly dry · Session resets in 10m")

        let tapped = self.hero([full, single(session: 100)], pin: "home")
        #expect(tapped.subtitle == "1 fresh · Work out of energy · Session resets in 10m")
    }

    @Test func allFreshAccountsCelebrate() {
        let accounts = ["a", "b", "c"].map {
            AccountUsage(
                id: AccountID($0), name: $0, windows: [Fixture.window(.session, used: 5)],
                observedAt: .reference())
        }
        #expect(hero(accounts).subtitle == "All 3 accounts fresh 🎉")
    }

    @Test func staleDataAsksForARefresh() {
        let hero = hero([single(session: 10)], now: .reference(601))
        #expect(hero.title == "Refresh needed")
        #expect(hero.subtitle == "Claude data is out of date.")
        #expect(hero.tone == .neutral)
    }

    @Test func unavailableMeterExplainsWhy() {
        let hero = hero([single(session: 10)], pin: "missing")
        #expect(hero.title == "Claude meter unavailable")
        #expect(hero.subtitle == "The selected Claude account is no longer configured.")
        #expect(hero.accessibilityLabel == "Claude meter unavailable. \(hero.subtitle)")
    }
}
