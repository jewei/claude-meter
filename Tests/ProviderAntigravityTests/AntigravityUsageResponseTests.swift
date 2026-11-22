import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import ProviderAntigravity

@Suite struct AntigravityUsageResponseTests {
    /// Captured 2026-11-22 from `agy -p /usage --output-format json` (agy 1.5.14).
    static let recordedUsage = Data(
        #"""
        {"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t100%\t2026-11-29T05:58:50Z\n","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit and a 5-hour limit.","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini 4 Neon, Gemini 4 Hydrogen","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.996646523475647,"reset_time":"2026-11-29T05:58:50Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.9882627725601196,"reset_time":"2026-11-22T10:58:50Z"}]},{"name":"Claude and GPT models","description":"Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.75,"reset_time":"2026-11-29T06:01:17Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.5,"reset_time":"2026-11-22T11:01:17Z"}]},{"name":"Gemini 4 Argon","buckets":[{"id":"gemini-argon-wtu-weekly","name":"Gemini 4 Argon Weekly Limit","window":"weekly","remaining_fraction":0.2,"reset_time":"2026-11-29T06:01:17Z"}]}]}}}
        """#.utf8)

    @Test func mapsRecordedPayloadToPrimaryAndScopedWindows() throws {
        let response = try AntigravityUsageResponse(data: Self.recordedUsage)
        #expect(
            response.windows.map(\.id) == [
                "gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly", "gemini-argon-wtu-weekly",
            ])

        let session = response.windows[0]
        #expect(session.title == "Gemini 5h")
        #expect(session.kind == .session)
        #expect(session.isBinding)
        #expect(session.duration == .hours(5))
        #expect(abs((session.usedPercent ?? -1) - 1.17372274398804) < 0.0001)
        #expect(session.resetsAt != nil)

        let weekly = response.windows[1]
        #expect(weekly.title == "Gemini Weekly")
        #expect(weekly.kind == .weekly)
        #expect(weekly.isBinding)
        #expect(weekly.duration == .days(7))
        #expect(abs((weekly.usedPercent ?? -1) - 0.3353476524353) < 0.0001)

        let thirdPartySession = response.windows[2]
        #expect(thirdPartySession.title == "Claude & GPT 5h")
        #expect(thirdPartySession.kind == .scoped)
        #expect(!thirdPartySession.isBinding)
        #expect(thirdPartySession.usedPercent == 50)
        #expect(thirdPartySession.duration == .hours(5))

        let thirdPartyWeekly = response.windows[3]
        #expect(thirdPartyWeekly.title == "Claude & GPT 7d")
        #expect(thirdPartyWeekly.kind == .scoped)
        #expect(!thirdPartyWeekly.isBinding)
        #expect(thirdPartyWeekly.usedPercent == 25)
        #expect(thirdPartyWeekly.duration == .days(7))

        let argon = response.windows[4]
        #expect(argon.title == "Gemini 4 Argon Weekly")
        #expect(argon.kind == .scoped)
        #expect(!argon.isBinding)
        #expect(argon.usedPercent == 80)
        #expect(argon.duration == .days(7))
    }

    @Test func fallsBackToFirstGroupWhenGeminiGroupIsAbsent() throws {
        let data = Data(
            #"""
            {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Custom Models","buckets":[{"id":"c-5h","window":"5h","remaining_fraction":0.4}]}]}}}
            """#.utf8)
        let response = try AntigravityUsageResponse(data: data)
        #expect(response.windows.count == 1)
        #expect(response.windows[0].title == "Custom 5h")
        #expect(response.windows[0].kind == .session)
        #expect(response.windows[0].isBinding)
        #expect(abs((response.windows[0].usedPercent ?? -1) - 60) < 0.0001)
    }

    @Test func marksOverLimitWhenRemainingFractionIsNegative() throws {
        let data = Data(
            #"""
            {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":-0.1}]}]}}}
            """#.utf8)
        let response = try AntigravityUsageResponse(data: data)
        let window = try #require(response.windows.first)
        #expect(window.usedPercent == 100)
        #expect(window.isOverLimit)
    }

    @Test func recognizesSignedOutErrorPayload() {
        let data = Data(
            #"""
            {"conversation_id":"","status":"ERROR","response":"","error":"authentication failed or timed out","finished_reason":"error"}
            """#.utf8)
        #expect(throws: AntigravityFailure.signedOut) {
            _ = try AntigravityUsageResponse(data: data)
        }
    }

    @Test func reportsOtherErrorsAndMalformedPayloads() {
        let backendError = Data(
            #"{"status":"ERROR","error":"upstream unavailable"}"#.utf8)
        #expect(throws: AntigravityFailure.commandFailed(detail: "upstream unavailable")) {
            _ = try AntigravityUsageResponse(data: backendError)
        }

        let emptyGroups = Data(
            #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[]}}}"#.utf8)
        #expect(throws: AntigravityFailure.noQuota) {
            _ = try AntigravityUsageResponse(data: emptyGroups)
        }

        let malformed = Data("not json".utf8)
        #expect(throws: AntigravityFailure.self) {
            _ = try AntigravityUsageResponse(data: malformed)
        }
    }
}
