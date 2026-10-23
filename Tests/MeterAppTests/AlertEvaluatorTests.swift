import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

/// Runs the evaluator over a sequence of observations, keeping its state like the app does.
struct AlertRun {
    var settings = Fixture.settings(enabled: [.claude, .cursor])
    var kinds: Set<Alert.Kind> = Set(Alert.Kind.allCases)
    var state = AlertEvaluator.State()

    /// Evaluates `readings` at `now`, which defaults to the newest observation.
    mutating func run(
        _ readings: [ProviderID: Reading<ProviderUsage>], now: Date? = nil,
        restored: Set<ProviderID> = []
    ) -> [Alert] {
        let newest = readings.values.compactMap(\.value?.observedAt).max() ?? .reference()
        let context = Fixture.context(
            settings, readings: readings, restored: restored, now: now ?? newest)
        let (alerts, state) = AlertEvaluator.evaluate(
            context, enabledKinds: kinds, previous: state)
        self.state = state
        return alerts
    }

    /// One Claude account `work` observed at `at`.
    mutating func claude(
        _ windows: [QuotaWindow], at: Date, owner: AccountOwner? = .identity("a"),
        now: Date? = nil
    ) -> [Alert] {
        let account = AccountUsage(
            id: "work", name: "work", windows: windows, observedAt: at, owner: owner)
        let usage = ProviderUsage(provider: .claude, accounts: [account])
        return run([.claude: .current(usage, observedAt: at)], now: now)
    }
}

/// A Claude session window that resets at `resetsAt`.
func session(
    _ used: Double, resetsAt: Date? = .reference(.hours(2)), duration: TimeInterval? = nil,
    id: String = "session", isBinding: Bool = true
) -> QuotaWindow {
    QuotaWindow(
        id: id, title: "Session", kind: .session, usedPercent: used, resetsAt: resetsAt,
        isBinding: isBinding, duration: duration)
}

@Suite struct AlertEvaluatorTests {
    private let reset = Date.reference(.hours(2))

    @Test func theFirstObservationIsASilentBaseline() {
        var run = AlertRun()
        #expect(run.claude([session(97)], at: .reference()).isEmpty)
        // The baseline marked the met condition, so the next refresh is silent too.
        #expect(run.claude([session(98)], at: .reference(60)).isEmpty)
    }

    @Test func aCrossingIntoCriticalAlertsOnce() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference())
        let alerts = run.claude([session(96)], at: .reference(60))
        #expect(alerts.map(\.kind) == [.lowEnergy])
        #expect(alerts.first?.body == "Claude Work: Session has 4% left. It refills in 1h 59m.")
        #expect(run.claude([session(97)], at: .reference(120)).isEmpty)
    }

    @Test func theCriticalBorderAlerts() {
        var below = AlertRun()
        _ = below.claude([session(50)], at: .reference())
        #expect(below.claude([session(94.9)], at: .reference(60)).isEmpty)
        var at = AlertRun()
        _ = at.claude([session(50)], at: .reference())
        #expect(at.claude([session(95)], at: .reference(60)).map(\.kind) == [.lowEnergy])
    }

    /// Low energy re-arms only below `critical − 5`, so a wobble sends one alert.
    @Test func lowEnergyHasHysteresis() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference())
        #expect(run.claude([session(96)], at: .reference(60)).count == 1)
        _ = run.claude([session(91)], at: .reference(120))
        #expect(run.claude([session(96)], at: .reference(180)).isEmpty)
        _ = run.claude([session(89)], at: .reference(240))
        #expect(run.claude([session(96)], at: .reference(300)).count == 1)
    }

    /// Without any reset time, plain hysteresis applies: two rises, two alerts.
    @Test func aWindowWithoutAResetAlertsOnEachRise() {
        var run = AlertRun()
        var count = 0
        for (step, used) in [50.0, 96, 50, 96].enumerated() {
            count +=
                run.claude([session(used, resetsAt: nil)], at: .reference(Double(step) * 60))
                .count
        }
        #expect(count == 2)
    }

    /// A reading without a reset time cannot clear the flag of a known period, so the next
    /// critical reading in that period stays silent.
    @Test func aReadingWithoutAResetDoesNotReArm() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference())
        #expect(run.claude([session(96)], at: .reference(60)).count == 1)
        _ = run.claude([session(10, resetsAt: nil)], at: .reference(120))
        #expect(run.claude([session(96)], at: .reference(180)).isEmpty)
    }

    @Test func aNewPeriodThatIsStillCriticalAlertsOnce() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference())
        #expect(run.claude([session(96)], at: .reference(60)).count == 1)
        let next = reset.addingTimeInterval(.hours(5))
        let after = reset.addingTimeInterval(60)
        #expect(run.claude([session(96, resetsAt: next)], at: after).map(\.kind) == [.lowEnergy])
        #expect(run.claude([session(97, resetsAt: next)], at: after + 60).isEmpty)
    }

    @Test func aHealthyNewPeriodAfterTroubleRefills() {
        var run = AlertRun()
        _ = run.claude([session(96)], at: .reference())
        let after = reset.addingTimeInterval(60)
        let alerts = run.claude(
            [session(8, resetsAt: reset.addingTimeInterval(.hours(5)))], at: after)
        #expect(alerts.map(\.kind) == [.refill])
        #expect(alerts.first?.body == "Claude Work: Session refilled. 92% left.")
    }

    /// Critical with reset R, then normal with no reset time, then normal with a later reset:
    /// one refill. A reading without a reset time leaves the period as it is.
    @Test func aReadingWithoutAResetDoesNotLoseTheRefill() {
        var run = AlertRun()
        _ = run.claude([session(96)], at: .reference())
        _ = run.claude([session(5, resetsAt: nil)], at: reset.addingTimeInterval(30))
        let alerts = run.claude(
            [session(5, resetsAt: reset.addingTimeInterval(.hours(5)))],
            at: reset.addingTimeInterval(60))
        #expect(alerts.map(\.kind) == [.refill])
    }

    /// The display resolves an expired window to 0%, which is not evidence of a refill.
    @Test func anExpiredWindowSendsNothingAndCanStillRefill() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference())
        // Observed before the reset, evaluated after it: expired, but still troubled.
        let late = reset.addingTimeInterval(30)
        #expect(run.claude([session(97)], at: reset.addingTimeInterval(-60), now: late).isEmpty)
        let alerts = run.claude(
            [session(5, resetsAt: reset.addingTimeInterval(.hours(5)))],
            at: reset.addingTimeInterval(60))
        #expect(alerts.map(\.kind) == [.refill])
    }

    @Test func aCorrectedResetIsNotANewPeriod() {
        var run = AlertRun()
        _ = run.claude([session(50)], at: .reference())
        #expect(run.claude([session(96)], at: .reference(60)).count == 1)
        let corrected = reset.addingTimeInterval(600)
        #expect(run.claude([session(96, resetsAt: corrected)], at: .reference(120)).isEmpty)
    }

    @Test func aResetThatBecomesKnownIsNotANewPeriod() {
        var run = AlertRun()
        _ = run.claude([session(96, resetsAt: nil)], at: .reference())
        #expect(run.claude([session(5)], at: .reference(60)).isEmpty)
    }

    /// A troubled period refills once; the next healthy period has a fresh `hadTrouble`.
    @Test func eachTransitionStartsAFreshPeriod() {
        var run = AlertRun()
        _ = run.claude([session(96)], at: .reference())
        let second = reset.addingTimeInterval(.hours(5))
        let third = second.addingTimeInterval(.hours(5))
        #expect(run.claude([session(5, resetsAt: second)], at: reset + 60).count == 1)
        #expect(run.claude([session(5, resetsAt: third)], at: second + 60).isEmpty)
    }

    /// Critical early, normal later in the same period: `hadTrouble` only accumulates.
    @Test func troubleEarlyInAPeriodStillRefills() {
        var run = AlertRun()
        _ = run.claude([session(96)], at: .reference())
        _ = run.claude([session(40)], at: .reference(60))
        let alerts = run.claude(
            [session(5, resetsAt: reset.addingTimeInterval(.hours(5)))], at: reset + 60)
        #expect(alerts.map(\.kind) == [.refill])
    }

    /// At 40% a window is normal, but a projected run-out is trouble too.
    @Test func aPeriodThatRanOutOnPaceRefills() {
        var run = AlertRun()
        run.kinds = [.refill]
        // 2 hours into a 5-hour window, 3 hours left: 50% runs out at hour 4.
        let window = session(50, resetsAt: .reference(.hours(3)), duration: .hours(5))
        _ = run.claude([window], at: .reference())
        let alerts = run.claude(
            [session(5, resetsAt: .reference(.hours(8)), duration: .hours(5))],
            at: .reference(.hours(3) + 60))
        #expect(alerts.map(\.kind) == [.refill])
    }

    @Test func runOutAlertsOncePerPeriodWithItsOwnID() throws {
        var run = AlertRun()
        _ = run.claude(
            [session(10, resetsAt: .reference(.hours(3)), duration: .hours(5))], at: .reference())
        let alerts = run.claude(
            [session(96, resetsAt: .reference(.hours(3)), duration: .hours(5))],
            at: .reference(60))
        #expect(Set(alerts.map(\.kind)) == [.lowEnergy, .runOut])
        let ids = Set(alerts.map(\.notificationID))
        #expect(ids.count == 2)
        let runOut = try #require(alerts.first { $0.kind == .runOut })
        #expect(runOut.body.hasPrefix("Claude Work: Session runs out in "))
        #expect(runOut.body.hasSuffix(" It refills in 2h 59m."))
    }

    /// A pass that lasts does not block the first projected run-out.
    @Test func aLastingPassDoesNotBlockTheFirstRunOut() {
        var run = AlertRun()
        run.kinds = [.runOut]
        let resetsAt = Date.reference(.hours(3))
        _ = run.claude([session(10, resetsAt: resetsAt, duration: .hours(5))], at: .reference())
        #expect(
            run.claude([session(20, resetsAt: resetsAt, duration: .hours(5))], at: .reference(60))
                .isEmpty)
        #expect(
            run.claude([session(60, resetsAt: resetsAt, duration: .hours(5))], at: .reference(120))
                .map(\.kind) == [.runOut])
    }

    @Test func nonBindingWindowsSendNoLowEnergyOrRefill() {
        var run = AlertRun()
        let api = session(100, id: "api", isBinding: false)
        _ = run.claude([session(10), session(10, id: "api", isBinding: false)], at: .reference())
        #expect(run.claude([session(10), api], at: .reference(60)).isEmpty)
        let alerts = run.claude(
            [
                session(10, resetsAt: reset + .hours(5)),
                session(5, resetsAt: reset + .hours(5), id: "api", isBinding: false),
            ],
            at: reset + 60)
        #expect(alerts.isEmpty)
    }

    @Test func aNonBindingWindowWithADurationRunsOut() {
        var run = AlertRun()
        run.kinds = [.runOut]
        func sonnet(_ used: Double) -> QuotaWindow {
            QuotaWindow(
                id: "seven_day_sonnet", title: "Sonnet Weekly", kind: .scoped, usedPercent: used,
                resetsAt: .reference(.days(3)), isBinding: false, duration: .days(7))
        }
        _ = run.claude([session(10), sonnet(20)], at: .reference())
        #expect(run.claude([session(10), sonnet(80)], at: .reference(60)).map(\.kind) == [.runOut])
    }

    @Test func aCursorBillingWindowRefillsAfterACriticalPeriod() {
        var run = AlertRun()
        func cursor(_ used: Double, resetsAt: Date, at: Date) -> [ProviderID: Reading<
            ProviderUsage
        >] {
            let account = AccountUsage(
                id: .default, name: "Cursor",
                windows: [
                    QuotaWindow(
                        id: "billing", title: "Billing period", kind: .billing, usedPercent: used,
                        resetsAt: resetsAt)
                ],
                observedAt: at, owner: .identity("c"))
            return [
                .cursor: .current(
                    ProviderUsage(provider: .cursor, accounts: [account]), observedAt: at)
            ]
        }
        _ = run.run(cursor(97, resetsAt: reset, at: .reference()))
        let alerts = run.run(cursor(3, resetsAt: reset + .days(30), at: reset + 60))
        #expect(alerts.map(\.kind) == [.refill])
        #expect(alerts.first?.body == "Cursor: Billing period refilled. 97% left.")
    }
}
