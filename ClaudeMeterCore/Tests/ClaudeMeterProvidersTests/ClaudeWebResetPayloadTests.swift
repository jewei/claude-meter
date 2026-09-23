import ClaudeMeterCore
import Foundation
import Testing

@testable import ClaudeMeterProviders

struct ClaudeWebResetPayloadTests {
    @Test func parsesTheWebOfferCountAndExpiry() throws {
        let data = Data(
            #"{"cedar_ember":{"eligible":true,"grants":[{"label":"Claude Opus 5.5 launch","resets_left":1,"starts_at":"2026-09-22T16:00:00+00:00","ends_at":"2026-10-22T16:00:00+00:00","paused":false}]}}"#
                .utf8)
        let resets = try #require(ClaudeWebResetPayload.parse(data))
        let beforeExpiry = try #require(ISO8601DateFormatter().date(from: "2026-09-23T00:00:00Z"))
        let afterExpiry = try #require(ISO8601DateFormatter().date(from: "2026-10-23T00:00:00Z"))

        #expect(resets.availableCount(asOf: beforeExpiry) == 1)
        #expect(resets.availableOffers(asOf: beforeExpiry).first?.title == "Claude Opus 5.5 launch")
        #expect(
            resets.availableOffers(asOf: beforeExpiry).first?.expiresAt
                == ISO8601DateFormatter().date(from: "2026-10-22T16:00:00Z"))
        #expect(resets.availableCount(asOf: afterExpiry) == 0)
    }

    @Test func treatsAnOAuthSurfaceDenialAsUnknown() {
        let data = Data(
            #"{"cedar_ember":{"eligible":false,"ineligible_reason":"surface","grants":[]}}"#.utf8)
        #expect(ClaudeWebResetPayload.parse(data) == nil)
    }

    @Test func rejectsInvalidExpiryWithoutLosingOtherOffers() throws {
        let data = Data(
            #"{"cedar_ember":{"eligible":true,"grants":[{"resets_left":1,"ends_at":"99999-01-01"},{"resets_left":2,"ends_at":"2026-10-22T16:00:00Z"}]}}"#
                .utf8)
        let resets = try #require(ClaudeWebResetPayload.parse(data))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-23T00:00:00Z"))
        #expect(resets.availableCount(asOf: now) == 2)
    }
}
