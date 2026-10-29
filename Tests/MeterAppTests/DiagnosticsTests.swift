import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@MainActor
@Suite struct DiagnosticsTests {
    @Test func aCurrentReadingCountsItsAccounts() {
        let one = Fixture.current(Fixture.usage(.claude, Fixture.account("home")))
        #expect(AppModel.describe(one).hasPrefix("current, 1 account, "))
        let two = Fixture.current(
            Fixture.usage(.claude, Fixture.account("home"), Fixture.account("work")))
        #expect(AppModel.describe(two).hasPrefix("current, 2 accounts, "))
    }
}
