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

    /// A provider error after a reading without observations keeps its accounts, each with
    /// its own issue. The failed refresh has an issue that no account carries, so it gets its
    /// own notice; the pinned account's hold is the hero's reason.
    @Test func aFailedRefreshThatNoAccountCarriesGetsANotice() throws {
        let hold = UsageIssue(
            "Anthropic is rate-limiting usage checks.", retryAt: .reference(.minutes(3)))
        let usage = Fixture.usage(
            .claude, .unavailable(id: "home", name: "home", issue: signIn),
            .unavailable(id: "work", name: "work", issue: hold))
        let settings = Fixture.settings { $0.menuBar.pinnedAccounts[.claude] = "work" }
        let model = try #require(
            accounts(settings, readings: [.claude: .failed(offline, partial: usage)]))
        #expect(
            model.hero.subtitle == "Anthropic is rate-limiting usage checks. Retrying in 3m.")
        #expect(model.notices.map(\.text) == ["Offline.", "Home: Sign in again."])
    }

    /// The same rule for a provider that is not the main meter: its cards state their
    /// accounts' own issues, and a failed refresh that no account carries is a notice with
    /// the provider's name. A first 429 holds the account with no observation; a provider
    /// error after it keeps that account (review R5-A-02).
    @Test func anotherProvidersFailedRefreshThatNoAccountCarriesGetsANotice() throws {
        let hold = UsageIssue(
            "Codex is rate-limiting usage checks.", retryAt: .reference(.minutes(3)))
        let held = Fixture.usage(.codex, .unavailable(id: "/h", name: "h", issue: hold))
        let claude = Fixture.current(Fixture.usage(.claude, Fixture.account("home")))
        let settings = Fixture.settings(enabled: [.claude, .codex])

        // The first 429: the account carries the issue, so only its card states it.
        let first = try #require(
            accounts(settings, readings: [.claude: claude, .codex: .failed(hold, partial: held)]))
        #expect(first.notices.isEmpty)
        let card = try #require(first.cards.first { $0.provider == .codex })
        #expect(
            card.status
                == StatusLine(
                    text: "Codex is rate-limiting usage checks. Retrying in 3m.", isFailure: true))

        // A provider error after it: no account carries that issue.
        let failed = try #require(
            accounts(
                settings, readings: [.claude: claude, .codex: .failed(offline, partial: held)]))
        #expect(failed.notices.map(\.text) == ["Codex: Offline."])
        #expect(failed.notices.map(\.kind) == [.warning])
        #expect(failed.cards.first { $0.provider == .codex }?.status == card.status)

        // A stale reading whose every account carries its own issue.
        let observed = Fixture.usage(.codex, Fixture.account("/h", issue: hold))
        let stale = try #require(
            accounts(
                settings,
                readings: [
                    .claude: claude,
                    .codex: .stale(observed, observedAt: .reference(), issue: signIn),
                ]))
        #expect(stale.notices.map(\.text) == ["Codex: Sign in again."])
        #expect(stale.notices.map(\.kind) == [.action])
        #expect(stale.cards.first { $0.provider == .codex }?.status == card.status)
    }
}
