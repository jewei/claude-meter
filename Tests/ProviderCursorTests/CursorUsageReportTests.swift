import Foundation
import MeterDomain
import Testing

@testable import ProviderCursor

/// The `GetCurrentPeriodUsage` mapping, without credentials or requests.
@Suite struct CursorUsageReportTests {
    private func report(_ json: String) throws -> CursorUsageReport {
        try CursorUsageReport(body: Data(json.utf8))
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

    @Test func percentagesAboveOneHundredStayOverLimit() throws {
        let report = try report(
            #"{"planUsage":{"totalPercentUsed":120,"autoPercentUsed":-5,"apiPercentUsed":"x"}}"#)
        #expect(report.windows.map(\.usedPercent) == [100, 0, nil])
        #expect(report.windows.map(\.isOverLimit) == [true, false, false])
    }
}
