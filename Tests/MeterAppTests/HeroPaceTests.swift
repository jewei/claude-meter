import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

/// The hero names the binding window that runs out first (`docs/product.md`, Pace).
@Suite struct HeroPaceTests {
    private func hero(
        _ accounts: [AccountUsage], pin: AccountID? = nil, now: Date = .reference()
    ) -> HeroModel {
        let settings = Fixture.settings { $0.menuBar.pinnedAccounts[.claude] = pin }
        let usage = ProviderUsage(provider: .claude, accounts: accounts)
        let context = Fixture.context(
            settings, readings: [.claude: Fixture.current(usage)], now: now)
        return HeroModel(MainMeter(context), context: context)
    }

    /// A 5-hour session, 2 hours in, that resets in 3 hours.
    private func session(used: Double) -> QuotaWindow {
        Fixture.window(.session, used: used, resetsIn: .hours(3), duration: .hours(5))
    }

    private func account(
        _ id: AccountID, name: String, _ windows: [QuotaWindow]
    ) -> AccountUsage {
        AccountUsage(id: id, name: name, windows: windows, observedAt: .reference())
    }

    @Test func aRunOutOfTheLimitingWindowSharesItsReset() {
        // 60% in 2 hours runs out 1h 20m later.
        let work = account(
            "work", name: "Work", [session(used: 60), Fixture.window(.weekly, used: 10)])
        #expect(
            hero([work]).subtitle
                == "Plenty in the tank · Session runs out in 1h\u{00A0}20m, resets in 3h")
    }

    /// Weekly has more pressure, but the session runs out first.
    @Test func theSoonestRunOutIsNotTheHighestPressure() {
        let weekly = Fixture.window(.weekly, used: 70, resetsIn: .hours(1), duration: .days(7))
        let work = account("work", name: "Work", [session(used: 50), weekly])
        #expect(
            hero([work]).subtitle
                == "Plenty in the tank · Session runs out in 2h · Weekly resets in 1h")
    }

    /// The projection passed before a new reading: the hero never asks ``Countdown`` for it.
    @Test func aPassedRunOutRunsOutNow() {
        // 99% in 2 hours runs out about 73 seconds later.
        let work = account(
            "work", name: "Work", [session(used: 99), Fixture.window(.weekly, used: 10)])
        #expect(
            hero([work], now: .reference(.minutes(5))).subtitle
                == "Almost dry · Session runs out now, resets in 2h\u{00A0}55m")
    }

    @Test func aRunOutOfAnotherAccountNamesIt() {
        let home = account("home", name: "Home", [session(used: 50)])
        let work = account("work", name: "Work", [Fixture.window(.session, used: 85)])
        #expect(
            hero([home, work], pin: "home").subtitle
                == "1 fresh · Work low · Home: Session runs out in 2h · Session resets in 2h")
    }

    @Test func freshAccountsStillNameARunOut() {
        let home = account("home", name: "Home", [session(used: 50)])
        let work = account("work", name: "Work", [Fixture.window(.session, used: 5)])
        #expect(
            hero([home, work], pin: "work").subtitle
                == "All 2 accounts fresh · Home: Session runs out in 2h")
    }

    /// Weekly is over its limit, so the session cannot run out first.
    @Test func anAccountOutOfEnergyNamesNoRunOut() {
        let weekly = Fixture.window(.weekly, used: 100, resetsIn: .days(2))
        let work = account("work", name: "Work", [session(used: 50), weekly])
        #expect(hero([work]).subtitle == "Out of energy · Weekly resets in 2d")
    }

    /// A non-binding window does not limit the account, so only its card shows the pace.
    @Test func aNonBindingRunOutIsNotNamed() {
        let sonnet = Fixture.window(
            .scoped, used: 80, resetsIn: .days(3), id: "seven_day_sonnet", title: "Sonnet Weekly",
            isBinding: false, duration: .days(7))
        let work = account("work", name: "Work", [Fixture.window(.session, used: 20), sonnet])
        #expect(hero([work]).subtitle == "Plenty in the tank · Session resets in 2h")
    }
}
