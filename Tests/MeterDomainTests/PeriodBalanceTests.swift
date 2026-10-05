import Foundation
import MeterDomain
import MeterTestSupport
import Testing

/// Balances that count one billing period end with the period.
@Suite struct PeriodBalanceTests {
    private let periodEnd = Date.reference(.hours(1))

    private func account(billingResetsAt: Date?) -> AccountUsage {
        AccountUsage(
            id: .default, name: "Account",
            windows: [
                QuotaWindow(
                    id: "billing", title: "Billing period", kind: .billing, usedPercent: 40,
                    resetsAt: billingResetsAt)
            ],
            balances: [
                Balance(kind: .spend, amount: 12, limit: 20, unit: .currency("USD")),
                Balance(kind: .onDemand, amount: 3, unit: .currency("USD")),
                Balance(kind: .prepaid, amount: 50, unit: .currency("USD")),
                Balance(kind: .credits, amount: 7, unit: .credits),
                Balance(kind: .extraUsage, amount: 5, limit: 10, unit: .currency("USD")),
            ],
            observedAt: .reference())
    }

    @Test(arguments: [true, false])
    func periodSpendEndsWithItsBillingWindow(isStale: Bool) {
        let usage = account(billingResetsAt: periodEnd)
        #expect(usage.resolved(at: .reference(), isStale: isStale).balances.count == 5)

        let after = usage.resolved(at: periodEnd, isStale: isStale)
        #expect(after.balances.map(\.kind) == [.prepaid, .credits, .extraUsage])
        // Resolution is idempotent.
        #expect(after.resolved(at: periodEnd.addingTimeInterval(60), isStale: isStale) == after)
    }

    @Test func aRetainedObservationDropsTheSpendOfAnEndedPeriod() {
        let retained = account(billingResetsAt: periodEnd)
            .retained(issue: UsageIssue("Offline"), now: periodEnd.addingTimeInterval(1))
        #expect(retained.balance(.spend) == nil)
        #expect(retained.balance(.onDemand) == nil)
        #expect(retained.balance(.prepaid)?.amount == 50)
    }

    @Test func aBillingWindowWithoutAResetKeepsEveryBalance() {
        let usage = account(billingResetsAt: nil)
        #expect(usage.resolved(at: .reference(.days(60)), isStale: true).balances.count == 5)
    }

    @Test func onlyABillingWindowEndsThePeriod() {
        var usage = account(billingResetsAt: nil)
        usage.windows.append(
            QuotaWindow(
                id: "session", title: "Session", kind: .session, usedPercent: 10,
                resetsAt: .reference(60)))
        #expect(usage.resolved(at: .reference(.hours(2)), isStale: true).balances.count == 5)
    }
}
