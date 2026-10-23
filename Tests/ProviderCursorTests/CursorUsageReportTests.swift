import Foundation
import MeterDomain
import Testing

@testable import ProviderCursor

/// The `GetCurrentPeriodUsage` mapping, without credentials or requests.
@Suite struct CursorUsageReportTests {
    private func report(_ json: String) throws -> CursorUsageReport {
        try CursorUsageReport(body: Data(json.utf8))
    }

    /// Only the billing window gets the period's length. The Auto and API rows share the
    /// period but do not limit the account.
    @Test func theBillingWindowHasThePeriodLength() throws {
        let report = try report(CursorFixture.usage)
        #expect(report.windows.map(\.id) == ["billing", "auto", "api"])
        #expect(report.windows.map(\.duration) == [2_592_200, nil, nil])
    }

    @Test func aMissingStartGivesNoLength() throws {
        let report = try report(#"{"billingCycleEnd":"1752592200000","planUsage":{}}"#)
        #expect(report.windows.first?.resetsAt != nil)
        #expect(report.windows.first?.duration == nil)
    }

    @Test func zeroLimitMeansNoFixedLimit() throws {
        let report = try report(#"{"planUsage":{"totalSpend":500,"limit":0,"totalPercentUsed":5}}"#)
        #expect(report.spend?.amount == 5)
        #expect(report.spend?.limit == nil)
    }

    @Test func olderResponsesHaveNoBreakdown() throws {
        let total = try report(#"{"planUsage":{"totalPercentUsed":5}}"#)
        #expect(total.windows.map(\.id) == ["billing"])
        let empty = try report("{}")
        #expect(empty.windows.map(\.usedPercent) == [nil])
        #expect(empty.spend == nil)
        #expect(empty.isEnabled)
    }

    /// Connect JSON omits proto3 zero values, so the start of a billing period arrives without
    /// the total or the spend. That is 0% used, not unknown.
    @Test(arguments: [
        #"{"planUsage":{}}"#, #"{"planUsage":{"limit":2000}}"#,
        #"{"planUsage":{"totalPercentUsed":null,"totalSpend":null}}"#,
    ])
    func anOmittedZeroInAPresentPlanUsageIsZero(body: String) throws {
        let report = try report(body)
        #expect(report.windows.map(\.id) == ["billing"])
        #expect(report.windows.first?.usedPercent == 0)
        #expect(report.spend?.amount == 0)
    }

    @Test func aMissingPlanUsageIsUnknownNotZero() throws {
        for body in ["{}", #"{"planUsage":null}"#, #"{"planUsage":"x"}"#] {
            let report = try report(body)
            #expect(report.windows.first?.usedPercent == nil, "\(body)")
            #expect(report.spend == nil, "\(body)")
        }
    }

    @Test func aValueThatIsNotANumberStaysUnknown() throws {
        let report = try report(#"{"planUsage":{"totalPercentUsed":"x","totalSpend":"y"}}"#)
        #expect(report.windows.first?.usedPercent == nil)
        #expect(report.spend == nil)
    }

    @Test func percentagesAboveOneHundredStayOverLimit() throws {
        let report = try report(
            #"{"planUsage":{"totalPercentUsed":120,"autoPercentUsed":-5,"apiPercentUsed":"x"}}"#)
        #expect(report.windows.map(\.usedPercent) == [100, 0, nil])
        #expect(report.windows.map(\.isOverLimit) == [true, false, false])
    }
}
