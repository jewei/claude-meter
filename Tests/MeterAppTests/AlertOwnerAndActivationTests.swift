import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

/// Owner changes, activations, and silent accounts (`docs/product.md` §8).
@Suite struct AlertOwnerAndActivationTests {
    private let reset = Date.reference(.hours(2))

    /// Login A had trouble; login B in the same slot is healthy in a later period. B never
    /// reads A's period, and its first observation is a silent baseline.
    @Test func aLoginSwitchSendsNoRefill() {
        var run = AlertRun()
        _ = run.claude([session(96)], at: .reference(), owner: .identity("a"))
        let alerts = run.claude(
            [session(5, resetsAt: reset + .hours(5))], at: reset + 60, owner: .identity("b"))
        #expect(alerts.isEmpty)
    }

    /// A token renewal changes a credential owner. The new baseline marks what is met.
    @Test func aTokenRenewalSendsNothing() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference(), owner: .credential("1"))
        #expect(run.claude([session(96)], at: .reference(60), owner: .credential("2")).isEmpty)
        #expect(run.claude([session(97)], at: .reference(120), owner: .credential("2")).isEmpty)
    }

    /// Both low energy and run-out are met at the owner change: neither alerts.
    @Test func anOwnerChangeSilencesEveryKind() {
        var run = AlertRun()
        let window = session(96, resetsAt: .reference(.hours(3)), duration: .hours(5))
        _ = run.claude([session(10)], at: .reference(), owner: .identity("a"))
        #expect(run.claude([window], at: .reference(60), owner: .identity("b")).isEmpty)
    }

    /// A stored nil is an owner: a later identity is a change, with a new baseline.
    @Test func aStoredNilOwnerIsAnOwner() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference(), owner: nil)
        #expect(run.claude([session(96)], at: .reference(60), owner: .identity("a")).isEmpty)
    }

    /// An owner change drops the state of every window of the account, also one that the
    /// observation lacks.
    @Test func anOwnerChangeResetsWindowsThatAreMissing() {
        var run = AlertRun()
        let opus = session(96, id: "opus")
        _ = run.claude([session(50), opus], at: .reference(), owner: .identity("a"))
        _ = run.claude([session(50)], at: .reference(60), owner: .identity("b"))
        let key = Alert.Key(provider: .claude, account: "work", window: "opus")
        #expect(run.state.windows[key]?.fired == [])
        #expect(run.state.windows[key]?.needsBaseline == true)
        #expect(
            run.claude([session(50), opus], at: .reference(120), owner: .identity("b")).isEmpty)
    }

    @Test func turningAKindOnAlertsOnceForAWindowThatAlreadyMeetsIt() {
        var run = AlertRun()
        _ = run.claude([session(96)], at: .reference())
        run.state.activate(.lowEnergy, providers: [.claude])
        #expect(run.claude([session(96)], at: .reference(60)).map(\.kind) == [.lowEnergy])
        #expect(run.claude([session(97)], at: .reference(120)).isEmpty)
    }

    /// The person asked for the confirmation, so a pending activation wins over the baseline
    /// of an owner change. The other kinds stay silent.
    @Test func aPendingActivationWinsOverAnOwnerChange() {
        var run = AlertRun()
        _ = run.claude([session(10)], at: .reference(), owner: .identity("a"))
        run.state.activate(.lowEnergy, providers: [.claude])
        let window = session(96, resetsAt: .reference(.hours(3)), duration: .hours(5))
        let alerts = run.claude([window], at: .reference(60), owner: .identity("b"))
        #expect(alerts.map(\.kind) == [.lowEnergy])
    }

    /// An activation whose condition is not met is consumed silently; the next rise alerts.
    @Test func anUnmetActivationIsConsumedSilently() {
        var run = AlertRun()
        _ = run.claude([session(10)], at: .reference(), owner: .identity("a"))
        run.state.activate(.lowEnergy, providers: [.claude])
        #expect(run.claude([session(20)], at: .reference(60), owner: .identity("b")).isEmpty)
        #expect(run.claude([session(96)], at: .reference(120), owner: .identity("b")).count == 1)
    }

    /// A consumed activation never replays, also after an owner change.
    @Test func anOwnerChangeDoesNotReplayAConsumedActivation() {
        var run = AlertRun()
        _ = run.claude([session(96)], at: .reference(), owner: .identity("a"))
        run.state.activate(.lowEnergy, providers: [.claude])
        #expect(run.claude([session(96)], at: .reference(60), owner: .identity("a")).count == 1)
        #expect(run.claude([session(96)], at: .reference(120), owner: .identity("b")).isEmpty)
    }

    /// Off and on again between `critical − 5` and critical: no alert then, one on the next
    /// rise.
    @Test func turningLowEnergyOffAndOnClearsItsFlag() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference())
        #expect(run.claude([session(96)], at: .reference(60)).count == 1)
        _ = run.claude([session(92)], at: .reference(120))
        run.state.deactivate(.lowEnergy)
        run.state.activate(.lowEnergy, providers: [.claude])
        #expect(run.claude([session(92)], at: .reference(180)).isEmpty)
        #expect(run.claude([session(96)], at: .reference(240)).count == 1)
    }

    /// Run-out on with no pace yet: the activation is consumed silently.
    @Test func anActivationWithoutAPaceIsConsumed() {
        var run = AlertRun()
        run.kinds = [.runOut]
        let resetsAt = Date.reference(.hours(3))
        _ = run.claude([session(10, resetsAt: resetsAt)], at: .reference())
        run.state.activate(.runOut, providers: [.claude])
        #expect(run.claude([session(60, resetsAt: resetsAt)], at: .reference(60)).isEmpty)
        #expect(
            run.claude([session(60, resetsAt: resetsAt, duration: .hours(5))], at: .reference(120))
                .map(\.kind) == [.runOut])
    }

    @Test func turningAKindOffDropsWhatIsPending() {
        var run = AlertRun()
        _ = run.claude([session(96)], at: .reference())
        run.state.activate(.lowEnergy, providers: [.claude])
        run.state.deactivate(.lowEnergy)
        #expect(run.claude([session(96)], at: .reference(60)).isEmpty)
    }

    /// A source turned off and on again forgets its windows: a silent baseline, not an alert
    /// for a crossing that the evaluator did not see.
    @Test func aSourceTurnedOffAndOnIsABaselineAgain() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference())
        run.settings.claude.isEnabled = false
        #expect(run.run([:], now: .reference(60)).isEmpty)
        #expect(run.state.windows.isEmpty)
        run.settings.claude.isEnabled = true
        #expect(run.claude([session(97)], at: .reference(120)).isEmpty)
    }

    @Test func aConfigDirTrackedAgainIsABaselineAgain() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference())
        run.settings.claude.disabledAccounts = ["work"]
        _ = run.claude([session(60)], at: .reference(60))
        run.settings.claude.disabledAccounts = []
        #expect(run.claude([session(97)], at: .reference(120)).isEmpty)
    }

    /// A provider enabled after the activation was not part of it: a silent baseline.
    @Test func aProviderEnabledLaterIsABaseline() {
        var run = AlertRun()
        run.state.activate(.lowEnergy, providers: [.cursor])
        #expect(run.claude([session(96)], at: .reference()).isEmpty)
    }

    @Test func staleUnobservedAndRestoredAccountsAreSilent() {
        var run = AlertRun()
        run.state.activate(.lowEnergy, providers: [.claude])
        let account = AccountUsage(
            id: "work", name: "work", windows: [session(96)], observedAt: .reference())
        let usage = ProviderUsage(provider: .claude, accounts: [account])
        let stale = Reading<ProviderUsage>.stale(
            usage, observedAt: .reference(), issue: UsageIssue("Offline"))
        #expect(run.run([.claude: stale]).isEmpty)
        #expect(
            run.run([.claude: .current(usage, observedAt: .reference())], restored: [.claude])
                .isEmpty)
        // Too old to be current.
        #expect(
            run.run([.claude: .current(usage, observedAt: .reference())], now: .reference(601))
                .isEmpty)
        // The activation is still pending for the first fresh observation.
        #expect(run.run([.claude: .current(usage, observedAt: .reference())]).count == 1)
    }

    /// Silence follows staleness, not issues.
    @Test func anAccountWithAnIssueThatIsNotStaleAlerts() {
        var run = AlertRun()
        run.state.activate(.lowEnergy, providers: [.claude])
        var account = AccountUsage(
            id: "work", name: "work", windows: [session(96)], observedAt: .reference())
        account.issue = UsageIssue("Reset details are rate-limited.")
        let usage = ProviderUsage(provider: .claude, accounts: [account])
        #expect(run.run([.claude: .current(usage, observedAt: .reference())]).count == 1)
    }

    @Test func untrackedAccountsAreSilent() {
        var run = AlertRun()
        run.settings.claude.disabledAccounts = ["work"]
        run.state.activate(.lowEnergy, providers: [.claude])
        #expect(run.claude([session(96)], at: .reference()).isEmpty)
    }

    /// Names are display names, through ``Redactor``, and values follow the meter mode.
    @Test func textUsesDisplayNamesAndTheMeterMode() {
        var run = AlertRun()
        run.settings.claude.accountNames = ["work": "me@example.com"]
        run.settings.appearance.meterMode = .used
        run.state.activate(.lowEnergy, providers: [.claude])
        let alert = run.claude([session(96, resetsAt: nil)], at: .reference()).first
        #expect(alert?.title == "Low energy")
        #expect(alert?.body == "Claude \(Redactor.redact("me@example.com")): Session is 96% used.")
        #expect(alert?.body.contains("example.com") == false)
    }

    @Test func observedAccountsDropUntrackedAccountsAndKeepStoredWindows() {
        var settings = Fixture.settings()
        settings.claude.disabledAccounts = ["off"]
        let expired = session(96, resetsAt: .reference(-60))
        let usage = ProviderUsage(
            provider: .claude,
            accounts: [
                AccountUsage(
                    id: "work", name: "work", windows: [expired], observedAt: .reference()),
                AccountUsage(id: "off", name: "off", windows: [expired], observedAt: .reference()),
            ])
        let context = Fixture.context(
            settings, readings: [.claude: .current(usage, observedAt: .reference())])
        #expect(context.observedAccounts(for: .claude).map(\.id) == ["work"])
        #expect(context.observedAccounts(for: .claude).first?.windows.first?.usedPercent == 96)
        #expect(context.accounts(for: .claude).map(\.id) == ["work", "off"])
        #expect(context.accounts(for: .claude).first?.windows.first?.usedPercent == 0)
    }
}
