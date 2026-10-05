import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct NoticeTests {
    private let signIn = UsageIssue("Sign in again.", needsAction: true)
    private let offline = UsageIssue("Offline.")

    private func accounts(
        _ settings: Settings, readings: [ProviderID: Reading<ProviderUsage>]
    ) -> AccountsModel? {
        let content = PopoverModel(Fixture.context(settings, readings: readings)).content
        guard case .accounts(let model) = content else { return nil }
        return model
    }

    /// With several accounts, an account notice puts the name in front of its issue. When
    /// that issue is why the pinned meter is unavailable, the hero states it and no notice
    /// repeats it (review R4-A-02).
    @Test func aPinnedAccountsIssueIsStatedOnceWithSeveralAccounts() throws {
        let usage = Fixture.usage(
            .claude, Fixture.account("home"),
            .unavailable(id: "work", name: "work", issue: signIn),
            .unavailable(id: "lab", name: "lab", issue: offline))
        let settings = Fixture.settings { $0.menuBar.pinnedAccounts[.claude] = "work" }
        let model = try #require(
            accounts(settings, readings: [.claude: Fixture.current(usage)]))
        #expect(model.hero.subtitle == "Sign in again.")
        #expect(model.notices.map(\.text) == ["Lab: Offline."])
    }

    /// Without a pin and with every account unavailable, the reason is the first account's
    /// issue. Only the other accounts get a notice.
    @Test func theReasonOfUnavailableAccountsIsStatedOnce() throws {
        let usage = Fixture.usage(
            .claude, .unavailable(id: "home", name: "home", issue: signIn),
            .unavailable(id: "work", name: "work", issue: offline))
        let model = try #require(
            accounts(
                Fixture.settings(), readings: [.claude: .failed(signIn, partial: usage)]))
        #expect(model.hero.subtitle == "Sign in again.")
        #expect(model.notices.map(\.text) == ["Work: Offline."])
    }
}
