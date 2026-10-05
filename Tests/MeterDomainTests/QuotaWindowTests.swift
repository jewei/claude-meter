import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@Suite struct QuotaWindowTests {
    private func window(_ used: Double?, resetsIn seconds: TimeInterval? = nil) -> QuotaWindow {
        QuotaWindow(
            id: "session", title: "Session", kind: .session, usedPercent: used,
            resetsAt: seconds.map { .reference($0) })
    }

    @Test func clampsPercentAndKeepsOverLimit() {
        #expect(window(120).usedPercent == 100)
        #expect(window(120).isOverLimit)
        #expect(window(100).isOverLimit == false)
        #expect(window(-5).usedPercent == 0)
    }

    @Test func nonFiniteValuesAreUnknown() {
        #expect(window(.nan).usedPercent == nil)
        #expect(window(.infinity).usedPercent == nil)
        #expect(window(.infinity).isOverLimit == false)
    }

    @Test func rejectsImplausibleResetDates() {
        let farFuture = QuotaWindow(
            id: "w", title: "W", kind: .weekly, usedPercent: 1,
            resetsAt: Date(timeIntervalSince1970: 1e15))
        #expect(farFuture.resetsAt == nil)
    }

    @Test func futureResetIsUnchanged() {
        let original = window(60, resetsIn: 60)
        #expect(original.resolved(at: .reference(), isStale: false) == original)
        #expect(original.resolved(at: .reference(), isStale: true) == original)
    }

    @Test func expiredCurrentWindowResetsToZero() {
        let resolved = window(120, resetsIn: -1).resolved(at: .reference(), isStale: false)
        #expect(resolved.usedPercent == 0)
        #expect(resolved.resetsAt == nil)
        #expect(resolved.isOverLimit == false)
    }

    @Test func resetInstantCountsAsExpired() {
        let resolved = window(60, resetsIn: 0).resolved(at: .reference(), isStale: false)
        #expect(resolved.usedPercent == 0)
    }

    @Test func expiredStaleWindowBecomesUnknown() {
        let resolved = window(60, resetsIn: -1).resolved(at: .reference(), isStale: true)
        #expect(resolved.usedPercent == nil)
        #expect(resolved.resetsAt == nil)
    }

    @Test func expiredUnknownWindowDropsItsReset() {
        let resolved = window(nil, resetsIn: -1).resolved(at: .reference(), isStale: false)
        #expect(resolved.usedPercent == nil)
        #expect(resolved.resetsAt == nil)
    }

    @Test func resolutionIsIdempotent() {
        let once = window(60, resetsIn: -1).resolved(at: .reference(), isStale: false)
        #expect(once.resolved(at: .reference(), isStale: false) == once)
    }

    @Test func pressureRanksOverLimitFirstAndUnknownLast() {
        #expect(window(120).pressure == 101)
        #expect(window(100).pressure == 100)
        #expect(window(0).pressure == 0)
        #expect(window(nil).pressure == -1)
    }

    @Test func decodingNormalizesStoredValues() throws {
        let json = #"""
            {"id":"w","title":"W","kind":"weekly","usedPercent":130,"isBinding":true,"isOverLimit":false}
            """#
        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: Data(json.utf8))
        #expect(decoded.usedPercent == 100)
        #expect(decoded.isOverLimit)
    }
}
