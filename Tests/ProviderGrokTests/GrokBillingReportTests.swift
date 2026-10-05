import Foundation
import MeterDomain
import Testing

@testable import ProviderGrok

/// The billing response mapping, without a sign-in file or requests.
@Suite struct GrokBillingReportTests {
    private func report(_ json: String) throws -> GrokBillingReport {
        try GrokBillingReport(body: Data(json.utf8))
    }

    @Test func anAbsentPercentWithAPeriodMeansZeroUsed() throws {
        let report = try report(
            #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"},"onDemandCap":{}}}"#)
        #expect(report.window.usedPercent == 0)
        #expect(report.onDemand.amount == 0)
        #expect(report.prepaid.amount == 0)
    }

    @Test func mapsMoneyInCents() throws {
        let report = try report(
            """
            {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","end":"2026-08-01T00:00:00+00:00"},"creditUsagePercent":12.5,"onDemandCap":{"val":1000},"onDemandUsed":{"val":42},"prepaidBalance":{"val":250}}}
            """)
        #expect(report.window.title == "Monthly")
        #expect(report.window.usedPercent == 12.5)
        #expect(report.onDemand.amount == Decimal(string: "0.42"))
        #expect(report.onDemand.limit == 10)
        #expect(report.prepaid.amount == Decimal(string: "2.5"))
    }

    @Test func readsNumbersSentAsStrings() throws {
        let report = try report(
            """
            {"config":{"currentPeriod":{"type":"OTHER"},"creditUsagePercent":"36.5","onDemandUsed":{"val":"1234"},"onDemandCap":{"val":"5000"},"prepaidBalance":{"val":"x"}}}
            """)
        #expect(report.window.title == "Credits")
        #expect(report.window.usedPercent == 36.5)
        #expect(report.onDemand.amount == Decimal(string: "12.34"))
        #expect(report.onDemand.limit == 50)
        #expect(report.prepaid.amount == nil)
    }
}
