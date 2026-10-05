import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@Suite struct AccountUsageDecodingTests {
    private func decode(_ json: String) throws -> AccountUsage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AccountUsage.self, from: Data(json.utf8))
    }

    @Test func decodingDropsDatesOutsideTheBounds() throws {
        let usage = try decode(
            #"""
            {"id":"a","name":"A","windows":[],"balances":[],"isStale":false,"sharesLogin":false,
             "observedAt":"4000-01-01T00:00:00Z","attemptedAt":"1900-01-01T00:00:00Z"}
            """#)
        #expect(usage.observedAt == nil)
        #expect(usage.attemptedAt == nil)
        #expect(!usage.hasObservation)
    }

    @Test func decodingKeepsValidDatesAndOptionalFields() throws {
        let usage = try decode(
            #"""
            {"id":"a","name":"A","plan":"Max","windows":[],"balances":[],"isStale":true,
             "sharesLogin":true,"observedAt":"2026-10-04T12:00:00Z",
             "owner":{"identity":{"_0":"abc"}}}
            """#)
        #expect(usage.observedAt == .reference())
        #expect(usage.attemptedAt == nil)
        #expect(usage.plan == "Max")
        #expect(usage.isStale && usage.sharesLogin)
        #expect(usage.owner == .identity("abc"))
    }

    @Test func settingADateOutsideTheBoundsMakesItUnknown() {
        var usage = AccountUsage(id: "a", name: "A", observedAt: .reference())
        usage.observedAt = Date(timeIntervalSince1970: 1e15)
        usage.attemptedAt = Date(timeIntervalSince1970: -1)
        #expect(usage.observedAt == nil)
        #expect(usage.attemptedAt == nil)
        usage.observedAt = .reference()
        #expect(usage.observedAt == .reference())
    }
}
