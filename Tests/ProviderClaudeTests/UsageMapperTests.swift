import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    @Suite struct UsageMapperTests {
        private func decode(_ json: String, now: Date = .reference()) throws -> UsageResponse {
            try UsageResponse(data: Data(json.utf8), now: now)
        }

        @Test func mapsEveryWindowWithItsIdTitleKindAndBinding() throws {
            let windows = UsageMapper.windows(try decode(ClaudeFixtures.fullUsage))

            #expect(
                windows.map(\.id) == [
                    "session", "weekly", "seven_day_opus", "seven_day_sonnet", "extra-usage",
                ])
            #expect(
                windows.map(\.title) == [
                    "Session", "Weekly", "Opus Weekly", "Sonnet Weekly", "Extra usage",
                ])
            #expect(windows.map(\.kind) == [.session, .weekly, .scoped, .scoped, .billing])
            #expect(windows.map(\.isBinding) == [true, true, true, false, false])
            #expect(windows.map(\.usedPercent) == [42, 61, 88, 34, 80.75])
            let sessionReset = try #require(windows[0].resetsAt)
            let wholeSecond = try #require(DateParsing.iso8601("2026-10-04T15:00:00Z"))
            #expect(abs(sessionReset.timeIntervalSince(wholeSecond) - 0.462) < 0.001)
            #expect(windows[4].resetsAt == nil)
        }

        @Test func extraUsageScalesMinorUnitsExactly() throws {
            let response = try decode(ClaudeFixtures.fullUsage)
            let balance = try #require(UsageMapper.balances(response).first)
            #expect(balance.kind == .extraUsage)
            #expect(balance.amount == Decimal(string: "16.15"))
            #expect(balance.limit == Decimal(string: "20"))
            #expect(balance.unit == .currency("USD"))
            #expect(balance.isPaused)

            let threePlaces = try decode(
                #"{"extra_usage": {"is_enabled": true, "used_credits": 1234, "monthly_limit": 50000, "decimal_places": 3}}"#
            )
            let scaled = try #require(UsageMapper.balances(threePlaces).first)
            #expect(scaled.amount == Decimal(string: "1.234"))
            #expect(scaled.limit == Decimal(string: "50"))
            #expect(!scaled.isPaused)
            #expect(UsageMapper.windows(threePlaces).last?.usedPercent == 1234.0 / 50000 * 100)
        }

        @Test func missingOrNullWindowsAreUnknownAndNeverFailTheResponse() throws {
            let response = try decode(
                #"{"five_hour": {"utilization": null}, "seven_day": "bad", "seven_day_opus": null, "extra_usage": null}"#
            )
            let windows = UsageMapper.windows(response)
            #expect(windows.map(\.id) == ["session", "weekly"])
            #expect(windows.allSatisfy { $0.usedPercent == nil && $0.resetsAt == nil })
            #expect(UsageMapper.balances(response).isEmpty)
            #expect(UsageMapper.resetAllowance(response) == nil)
        }

        @Test func opusRowAppearsOnlyWithAValue() throws {
            let unknown = try decode(#"{"seven_day_opus": {"utilization": null}}"#)
            #expect(!UsageMapper.windows(unknown).contains { $0.id == "seven_day_opus" })
        }

        @Test func numericResetTimesAreEpochSeconds() throws {
            let response = try decode(
                #"{"five_hour": {"utilization": 5, "resets_at": 1791126000}}"#)
            #expect(response.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_791_126_000))
        }

        @Test func scopedWindowsAreSortedAndNullScopesDropped() throws {
            let response = try decode(
                """
                {"seven_day_sonnet": {"utilization": 34}, "seven_day_cowork": {"utilization": null},
                 "seven_day_oauth_apps": {"utilization": 2}, "seven_day_x": 5, "seven_day_y": null}
                """)
            #expect(response.scoped.map(\.key) == ["seven_day_oauth_apps", "seven_day_sonnet"])
            #expect(
                UsageMapper.windows(response).map(\.title) == [
                    "Session", "Weekly", "Oauth Apps Weekly", "Sonnet Weekly",
                ])
        }

        @Test func limitsArrayFillsGapsAndFlatFieldsWin() throws {
            let response = try decode(
                """
                {"seven_day_sonnet": {"utilization": 34},
                 "seven_day_haiku": {"utilization": null},
                 "limits": [
                   {"kind": "weekly_scoped", "percent": 88, "resets_at": "2026-10-09T07:00:00Z",
                    "scope": {"model": {"display_name": "Claude Opus 4"}}},
                   {"kind": "weekly_scoped", "percent": 1, "scope": {"model": {"display_name": "Opus 4.5"}}},
                   {"kind": "weekly_scoped", "percent": 99, "scope": {"model": {"display_name": "Sonnet 4.5"}}},
                   {"kind": "weekly_scoped", "percent": 12, "scope": {"model": {"display_name": "Haiku 4.5"}}},
                   {"kind": "weekly_scoped", "percent": 50, "scope": {"model": {"display_name": "Fable"}}},
                   {"kind": "weekly_scoped", "scope": {"model": {"display_name": "Nopercent"}}},
                   {"kind": "weekly_scoped", "percent": 7},
                   {"kind": "session", "percent": 60},
                   {"kind": "weekly_all", "percent": 70},
                   "malformed"
                 ]}
                """)
            #expect(response.sevenDayOpus?.utilization == 88)
            #expect(response.sevenDayOpus?.resetsAt == DateParsing.iso8601("2026-10-09T07:00:00Z"))
            #expect(
                response.scoped.map(\.key) == [
                    "seven_day_fable", "seven_day_haiku", "seven_day_sonnet",
                ])
            #expect(response.scoped.map(\.window.utilization) == [50, 12, 34])
            #expect(response.fiveHour == nil)
        }

        @Test func resetGrantsKeepOnlyStartedUnexpiredGrantsWithResetsLeft() throws {
            let response = try decode(
                """
                {"cedar_ember": {"eligible": true, "grants": [
                  {"label": " Launch reset ", "resets_left": 2, "starts_at": "2026-09-22T16:00:00Z",
                   "ends_at": "2026-10-22T16:00:00Z"},
                  {"label": "Bad date", "resets_left": 1, "ends_at": "not a date"},
                  {"label": "Future", "resets_left": 1, "starts_at": "2026-10-05T00:00:00Z"},
                  {"label": "Expired", "resets_left": 1, "ends_at": "2026-10-04T11:00:00Z"},
                  {"label": "Empty", "resets_left": 0},
                  {"label": "Word", "resets_left": "one"},
                  {"label": "", "resets_left": 500},
                  {"label": "After the limit", "resets_left": 5}
                ]}}
                """)
            let grants = try #require(response.resetGrants)
            #expect(grants.map(\.title) == ["Launch reset", "Bad date", "Usage reset"])
            // At most 99 resets in total: the large grant fills the rest, and later grants
            // are not read.
            #expect(grants.map(\.resetsLeft) == [2, 1, 96])
            #expect(grants[0].expiresAt == DateParsing.iso8601("2026-10-22T16:00:00Z"))
            #expect(grants[1].expiresAt == nil)

            let allowance = try #require(UsageMapper.resetAllowance(response))
            #expect(allowance.available == 99)
            #expect(allowance.resets.count == 99)
            #expect(allowance.resets.first?.title == "Launch reset")
        }

        @Test func anEmptyCurrencyIsUSDAndAKeyWithoutAScopeIsDropped() throws {
            let response = try decode(
                """
                {"extra_usage": {"is_enabled": true, "used_credits": 1, "currency": " "},
                 "seven_day_": {"utilization": 5}, "seven_day__": {"utilization": 6}}
                """)
            #expect(UsageMapper.balances(response).first?.unit == .currency("USD"))
            #expect(response.scoped.isEmpty)
            #expect(UsageMapper.scopeTitle("seven_day_") == "Other Weekly")
        }

        @Test(
            arguments: [
                (#"{"eligible": false, "ineligible_reason": "surface"}"#, nil),
                (#"{"eligible": false, "ineligible_reason": "not_in_program"}"#, 0),
                (#"{"eligible": true, "grants": []}"#, 0),
                (#"{"eligible": true}"#, nil),
                (#"{"eligible": true, "grants": "bad"}"#, nil),
                (#"{"eligible": true, "grants": [1]}"#, nil),
            ] as [(String, Int?)])
        func unrecognizedSurfaceIsUnknownButOutsideTheProgramIsZero(
            allowance: String, available: Int?
        )
            throws
        {
            let response = try decode(
                #"{"five_hour": {"utilization": 5}, "cedar_ember": \#(allowance)}"#)
            #expect(UsageMapper.resetAllowance(response)?.available == available)
            #expect(UsageMapper.windows(response)[0].usedPercent == 5)
        }

        @Test func aBodyThatIsNotAnObjectIsInvalid() {
            #expect(throws: UsageResponse.InvalidBody.self) { try decode("[]") }
            #expect(throws: UsageResponse.InvalidBody.self) { try decode("<html>") }
        }

        @Test func overLimitValuesKeepTheirSeverity() throws {
            let window = UsageMapper.windows(try decode(ClaudeFixtures.usage(session: 120)))[0]
            #expect(window.usedPercent == 100)
            #expect(window.isOverLimit)
        }
    }
}
