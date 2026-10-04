import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct PopoverModelTests {
    private func content(
        _ settings: Settings, readings: [ProviderID: Reading<ProviderUsage>] = [:],
        refreshing: Set<ProviderID> = []
    ) -> PopoverModel.Content {
        PopoverModel(Fixture.context(settings, readings: readings, refreshing: refreshing)).content
    }

    @Test func welcomesNewUsers() {
        var settings = Fixture.settings()
        settings.hasCompletedOnboarding = false
        let model = PopoverModel(Fixture.context(settings, readings: [:]))
        #expect(model.content == .status(.onboarding))
        #expect(model.updatedText == nil)
        #expect(!model.showsQuit)
    }

    @Test func pausedWithoutDataExplainsPause() {
        let settings = Fixture.settings { $0.isPaused = true }
        #expect(content(settings) == .status(.paused))
    }

    @Test func pausedWithDataKeepsShowingIt() {
        let settings = Fixture.settings { $0.isPaused = true }
        let usage = Fixture.usage(.claude, Fixture.account("a"))
        guard case .accounts = content(settings, readings: [.claude: Fixture.current(usage)]) else {
            Issue.record("Expected accounts")
            return
        }
    }

    @Test func noEnabledSources() {
        #expect(content(Fixture.settings(enabled: [])) == .status(.noSources))
    }

    @Test func loadsBeforeTheFirstReading() {
        #expect(content(Fixture.settings(), refreshing: [.claude]) == .loading("Checking Claude…"))
        #expect(
            content(Fixture.settings(enabled: [.claude, .cursor]), refreshing: [.cursor])
                == .loading("Checking your tanks…"))
    }

    @Test func failureWithoutCardsShowsTheError() {
        let content = content(
            Fixture.settings(), readings: [.claude: .failed(UsageIssue("Sign in to Claude Code."))])
        #expect(content == .status(.error(.claude, message: "Sign in to Claude Code.")))
    }

    @Test func nothingYetGivesSetupHelp() {
        guard case .status(let screen) = content(Fixture.settings(enabled: [.codex])) else {
            Issue.record("Expected a status screen")
            return
        }
        #expect(screen.title == "No usage yet")
        #expect(screen.message.contains("codex login"))
    }

    @Test func headerShowsTheMainObservationAge() {
        let usage = Fixture.usage(.claude, Fixture.account("a", observedAt: .reference(-125)))
        let model = PopoverModel(
            Fixture.context(Fixture.settings(), readings: [.claude: Fixture.current(usage)]))
        #expect(model.updatedText == "2m ago")
    }

    @Test func noticesNameFailedAccountsOnce() throws {
        let issue = UsageIssue("Sign in again.", needsAction: true)
        let usage = Fixture.usage(
            .claude, Fixture.account("home"), Fixture.account("work", issue: issue))
        let reading = Reading<ProviderUsage>.stale(usage, observedAt: .reference(), issue: issue)
        guard case .accounts(let model) = content(Fixture.settings(), readings: [.claude: reading])
        else {
            Issue.record("Expected accounts")
            return
        }
        #expect(model.notices.map(\.text) == ["Sign in again.", "Work: Sign in again."])
        #expect(model.notices.allSatisfy { $0.kind == .action })
    }

    @Test func failedProviderWithoutCardsGetsANotice() {
        let claude = Fixture.usage(.claude, Fixture.account("a"))
        let content = content(
            Fixture.settings(enabled: [.claude, .grok]),
            readings: [
                .claude: Fixture.current(claude), .grok: .failed(UsageIssue("Run grok login.")),
            ])
        guard case .accounts(let model) = content else {
            Issue.record("Expected accounts")
            return
        }
        #expect(model.notices.map(\.text) == ["Grok: Run grok login."])
    }

    @Test func dragHintNeedsTwoEligibleCards() {
        let one = Fixture.usage(.claude, Fixture.account("a"))
        let two = Fixture.usage(.claude, Fixture.account("a"), Fixture.account("b"))
        guard
            case .accounts(let single) = content(
                Fixture.settings(), readings: [.claude: Fixture.current(one)]),
            case .accounts(let double) = content(
                Fixture.settings(), readings: [.claude: Fixture.current(two)])
        else {
            Issue.record("Expected accounts")
            return
        }
        #expect(single.dragHint == nil)
        #expect(double.dragHint != nil)
        #expect(double.showsRingLegend)
    }
}
