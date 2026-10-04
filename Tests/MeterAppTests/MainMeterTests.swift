import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct MainMeterTests {
    private func meter(
        _ accounts: [AccountUsage], pin: AccountID? = nil, enabled: Set<ProviderID> = [.claude],
        reading: ((ProviderUsage) -> Reading<ProviderUsage>)? = nil, now: Date = .reference()
    ) -> MainMeter {
        let usage = ProviderUsage(provider: .claude, accounts: accounts)
        let settings = Fixture.settings(enabled: enabled) {
            $0.menuBar.pinnedAccounts[.claude] = pin
        }
        let context = Fixture.context(
            settings, readings: [.claude: reading?(usage) ?? Fixture.current(usage)], now: now)
        return MainMeter(context)
    }

    @Test func selectsTheAccountNearestItsLimit() {
        let meter = meter([
            Fixture.account("home", session: 20), Fixture.account("work", session: 80),
        ])
        #expect(meter.selected?.id == "work")
        #expect(meter.severity == .warning)
        #expect(meter.cardID == .account(.claude, "work"))
    }

    @Test func exactPinWinsAndLimitsSeverity() {
        let meter = meter(
            [Fixture.account("home", session: 20), Fixture.account("work", session: 99)],
            pin: "home")
        #expect(meter.selected?.id == "home")
        #expect(meter.severity == .normal)
    }

    @Test func missingPinIsUnavailableWithoutFallback() {
        let meter = meter([Fixture.account("home")], pin: "gone")
        #expect(meter.selected == nil)
        #expect(meter.severity == .unknown)
        #expect(meter.issue?.message == "The selected Claude account is no longer configured.")
    }

    @Test func pinnedAccountWithoutReadingExplainsItself() {
        let meter = meter([Fixture.account("home", observedAt: nil)], pin: "home")
        #expect(meter.issue?.message == "The selected Claude account has no usage reading.")
    }

    @Test func offProviderWithoutAnotherMainProviderExplainsItself() {
        let meter = meter([Fixture.account("home")], enabled: [.cursor])
        #expect(meter.provider == .claude)
        #expect(meter.selected == nil)
        #expect(meter.issue?.message == "Claude is off. Turn it on in Settings > Data.")
    }

    @Test func unconnectedClaudeAsksToConnect() {
        let settings = Fixture.settings(enabled: [.claude]) { $0.claude.connection = .off }
        let meter = MainMeter(Fixture.context(settings, readings: [:]))
        #expect(meter.provider == .claude)
        #expect(meter.issue?.message == "Connect Claude in Settings > Data.")
    }

    @Test func offMainProviderYieldsToTheProviderInUse() {
        let codex = Fixture.usage(.codex, Fixture.account("/h"))
        for configure: (inout Settings) -> Void in [
            { $0.claude.connection = .off }, { $0.claude.isEnabled = false },
        ] {
            let settings = Fixture.settings(enabled: [.claude, .codex], configure: configure)
            let meter = MainMeter(
                Fixture.context(settings, readings: [.codex: Fixture.current(codex)]))
            #expect(meter.provider == .codex)
            #expect(meter.selected?.id == "/h")
        }
    }

    @Test func providerInUseNeverYieldsToTheOther() {
        let settings = Fixture.settings(enabled: [.claude, .codex])
        let codex = Fixture.usage(.codex, Fixture.account("/h"))
        let meter = MainMeter(
            Fixture.context(
                settings,
                readings: [
                    .claude: .failed(UsageIssue("Sign in again.")), .codex: Fixture.current(codex),
                ]))
        #expect(meter.provider == .claude)
        #expect(meter.selected == nil)
        #expect(meter.issue?.message == "Sign in again.")
    }

    @Test func missingCodexPinNeverFallsBackToAnotherCodexAccount() {
        let settings = Fixture.settings(enabled: [.codex], main: .codex) {
            $0.menuBar.pinnedAccounts[.codex] = "/gone"
        }
        let codex = Fixture.usage(.codex, Fixture.account("/h"))
        let meter = MainMeter(Fixture.context(settings, readings: [.codex: Fixture.current(codex)]))
        #expect(meter.provider == .codex)
        #expect(meter.selected == nil)
        #expect(meter.issue?.message == "The selected Codex account is no longer configured.")
    }

    @Test func oldObservationsAreStale() {
        let fresh = meter([Fixture.account("home")], now: .reference(600))
        let old = meter([Fixture.account("home")], now: .reference(601))
        #expect(!fresh.isStale)
        #expect(old.isStale)
    }

    @Test func futureObservationsBeyondSkewAreStale() {
        let meter = meter([Fixture.account("home", observedAt: .reference(301))])
        #expect(meter.isStale)
    }

    @Test func failedRefreshMakesTheReadingStale() {
        let meter = meter([Fixture.account("home")]) {
            .stale($0, observedAt: .reference(), issue: UsageIssue("Offline"))
        }
        #expect(meter.isStale)
        #expect(meter.issue?.message == "Offline")
    }

    @Test func displayNamesAndPlanOverridesApply() {
        let usage = Fixture.usage(.claude, Fixture.account("claude-work"))
        let settings = Fixture.settings {
            $0.claude.planOverrides = ["claude-work": "Pro"]
        }
        let context = Fixture.context(settings, readings: [.claude: Fixture.current(usage)])
        #expect(context.accounts(for: .claude).first?.name == "Claude Work")
        #expect(context.accounts(for: .claude).first?.plan == "Pro")

        var named = settings
        named.claude.accountNames = ["claude-work": "Day job"]
        let renamed = Fixture.context(named, readings: [.claude: Fixture.current(usage)])
        #expect(renamed.accounts(for: .claude).first?.name == "Day job")
    }

    @Test func reportedPlanWinsOverTheOverride() {
        let usage = Fixture.usage(.claude, Fixture.account("claude", plan: "Max 20x"))
        let settings = Fixture.settings { $0.claude.planOverrides = ["claude": "Pro"] }
        let context = Fixture.context(settings, readings: [.claude: Fixture.current(usage)])
        #expect(context.accounts(for: .claude).first?.plan == "Max 20x")
    }
}

@Suite struct MenuBarModelTests {
    private func model(
        _ account: AccountUsage, configure: (inout Settings) -> Void = { _ in },
        refreshing: Set<ProviderID> = [], now: Date = .reference()
    ) -> MenuBarModel {
        let settings = Fixture.settings(configure: configure)
        let reading = Fixture.current(Fixture.usage(.claude, account))
        return MenuBarModel(
            Fixture.context(
                settings, readings: [.claude: reading], refreshing: refreshing, now: now))
    }

    @Test func showsTheSessionWindowByDefault() {
        let model = model(Fixture.account("a", session: 1, weekly: 27))
        #expect(model.text == "99% 5h")
        #expect(model.icon == .bolt(.dot(.normal)))
        #expect(!model.isDimmed)
    }

    @Test func fallsBackToWeeklyWithoutASessionValue() {
        let model = model(Fixture.account("a", session: nil, weekly: 27))
        #expect(model.text == "73% 7d")
    }

    @Test func showsBothWindowsOrUsedPercentages() {
        let both = model(Fixture.account("a", session: 1, weekly: 27)) {
            $0.appearance.menuBarWindow = .both
        }
        #expect(both.text == "99% 5h · 73% 7d")
        let used = model(Fixture.account("a", session: 1, weekly: 27)) {
            $0.appearance.meterMode = .used
            $0.appearance.menuBarWindow = .weekly
        }
        #expect(used.text == "27% 7d")
    }

    @Test func exhaustedAtExactlyOneHundredPercent() {
        #expect(model(Fixture.account("a", session: 100)).icon == .bolt(.exhausted))
        #expect(model(Fixture.account("a", session: 96)).icon == .bolt(.dot(.critical)))
    }

    @Test func staleHidesTheNumber() {
        let model = model(Fixture.account("a"), now: .reference(601))
        #expect(model.icon == .bolt(.stale))
        #expect(model.text == nil)
        #expect(model.accessibilityLabel == "Claude Meter. Claude. Data is stale.")
    }

    @Test func pausedDimsAndHidesTheNumber() {
        let model = model(Fixture.account("a")) { $0.isPaused = true }
        #expect(model.isDimmed)
        #expect(model.text == nil)
        #expect(model.icon == .bolt(.none))
        #expect(model.accessibilityLabel == "Claude Meter. Claude. Paused.")
    }

    @Test func spokenSummaryNamesWindowAndSeverity() {
        let model = model(Fixture.account("a", session: 85, weekly: 10))
        #expect(
            model.accessibilityLabel
                == "Claude Meter. Claude. Session 15 percent left. Overall quota warning.")
    }

    @Test func loadingAndErrorIcons() {
        let settings = Fixture.settings()
        let loading = MenuBarModel(Fixture.context(settings, readings: [:], refreshing: [.claude]))
        #expect(loading.icon == .loading)
        #expect(loading.accessibilityLabel == "Claude Meter. Claude. Loading.")
        let failed = MenuBarModel(
            Fixture.context(settings, readings: [.claude: .failed(UsageIssue("Sign in"))]))
        #expect(failed.icon == .error)
        #expect(failed.accessibilityLabel == "Claude Meter. Claude. Usage unavailable.")
    }

    @Test func notSetUpShowsACalmDimmedBolt() {
        // The first launch: Claude's switch is on, nothing is connected or read yet.
        var fresh = Settings()
        let first = MenuBarModel(Fixture.context(fresh, readings: [:]))
        #expect(first.icon == .bolt(.none))
        #expect(first.isDimmed)
        #expect(first.text == nil)
        #expect(first.accessibilityLabel == "Claude Meter. Not set up.")
        // Connected before onboarding, with a failure left from an earlier run.
        fresh.claude.connection = .automatic
        let failed = MenuBarModel(
            Fixture.context(fresh, readings: [.claude: .failed(UsageIssue("Sign in"))]))
        #expect(failed.icon == .bolt(.none))
        #expect(failed.accessibilityLabel == "Claude Meter. Not set up.")
    }

    @Test func pausedWithoutDataShowsACalmDimmedBolt() {
        let settings = Fixture.settings { $0.isPaused = true }
        let paused = MenuBarModel(
            Fixture.context(settings, readings: [.claude: .failed(UsageIssue("Sign in"))]))
        #expect(paused.icon == .bolt(.none))
        #expect(paused.isDimmed)
        #expect(paused.accessibilityLabel == "Claude Meter. Claude. Paused.")
    }

    @Test func noReadingYetIsNotAnError() {
        let model = MenuBarModel(Fixture.context(Fixture.settings(), readings: [:]))
        #expect(model.icon == .bolt(.none))
        #expect(!model.isDimmed)
        let off = MenuBarModel(Fixture.context(Fixture.settings(enabled: [.cursor]), readings: [:]))
        #expect(off.icon == .bolt(.none))
    }

    @Test func missingPinShowsTheWarningBolt() {
        let model = model(Fixture.account("a")) { $0.menuBar.pinnedAccounts[.claude] = "gone" }
        #expect(model.icon == .error)
        #expect(model.text == nil)
    }

    @Test func menuBarDotUsesEveryAccountWithoutAPin() {
        let usage = Fixture.usage(
            .claude, Fixture.account("home", session: 10), Fixture.account("work", session: 96))
        let unpinned = MenuBarModel(
            Fixture.context(Fixture.settings(), readings: [.claude: Fixture.current(usage)]))
        #expect(unpinned.icon == .bolt(.dot(.critical)))
        let pinned = MenuBarModel(
            Fixture.context(
                Fixture.settings { $0.menuBar.pinnedAccounts[.claude] = "home" },
                readings: [.claude: Fixture.current(usage)]))
        #expect(pinned.icon == .bolt(.dot(.normal)))
        #expect(pinned.text == "90% 5h")
    }

    @Test func menuBarTextAndSpeechResolveAtReset() {
        // Observed a minute before the 2 h reset, rendered at the reset.
        let account = Fixture.account(
            "a", session: 85, observedAt: .reference(.hours(2) - .minutes(1)))
        let model = model(account, now: .reference(.hours(2)))
        #expect(model.text == "100% 5h")
        #expect(
            model.accessibilityLabel
                == "Claude Meter. Claude. Session 100 percent left. Overall quota is normal.")
    }

    @Test func spokenSummaryBothWindowsAndRefreshingSuffix() {
        let model = model(
            Fixture.account("a", session: 1, weekly: 27),
            configure: { $0.appearance.menuBarWindow = .both },
            refreshing: [.claude])
        #expect(
            model.accessibilityLabel
                == "Claude Meter. Claude. Session 99 percent left. Weekly 73 percent left. "
                + "Overall quota is normal. Refreshing.")
    }

    @Test func percentRoundingAtTheEdges() {
        let cases: [(Double, Int)] = [
            (0, 0), (0.01, 1), (0.4, 1), (0.5, 1), (1.4, 1), (50.5, 51), (99.4, 99), (99.6, 99),
            (99.99, 99), (100, 100),
        ]
        for (value, shown) in cases {
            #expect(Formatting.wholePercent(value) == shown, "\(value)")
        }
        let almostEmpty = model(Fixture.account("a", session: 99.6))
        #expect(almostEmpty.text == "1% 5h")
        #expect(almostEmpty.icon == .bolt(.dot(.critical)))
        #expect(almostEmpty.accessibilityLabel.contains("Session 1 percent left."))
        #expect(model(Fixture.account("a", session: 0.4)).text == "99% 5h")
        let used = model(Fixture.account("a", session: 0.4)) { $0.appearance.meterMode = .used }
        #expect(used.text == "1% 5h")
        #expect(model(Fixture.account("a", session: 100)).text == "0% 5h")
    }
}
