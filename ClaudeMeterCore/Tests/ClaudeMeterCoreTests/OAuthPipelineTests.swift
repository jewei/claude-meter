import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite("OAuthPipeline")
struct OAuthPipelineTests {
  @Test func decodesUsageResponseWithExtraFields() throws {
    let json = """
    {"five_hour":{"utilization":81.0,"resets_at":"2026-06-23T11:30:00.462328+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day":{"utilization":61.0,"resets_at":"2026-06-27T07:00:00.462348+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null},"seven_day_oauth_apps":null,"limits":[],"spend":{},"extra_usage":{"is_enabled":false}}
    """
    let data = try #require(json.data(using: .utf8))
    let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
    #expect(usage.fiveHour?.utilization == 81.0)
    #expect(usage.sevenDay?.utilization == 61.0)
  }

  @Test func verificationPercentagesUseApiPercentScale() throws {
    let json = """
    {"five_hour":{"utilization":81.0},"seven_day":{"utilization":61.0}}
    """
    let data = try #require(json.data(using: .utf8))
    let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
    let percentages = OAuthPipeline.verificationPercentages(from: usage)
    #expect(percentages.sessionPct == 81.0)
    #expect(percentages.weekPct == 61.0)
  }

  @Test func decodesOpusWeeklyAndExtraUsage() throws {
    let json = """
    {"five_hour":{"utilization":40.0,"resets_at":"2026-06-24T15:00:00+00:00"},
     "seven_day":{"utilization":55.0,"resets_at":"2026-06-30T07:00:00+00:00"},
     "seven_day_opus":{"utilization":88.0,"resets_at":"2026-06-30T07:00:00+00:00"},
     "extra_usage":{"is_enabled":false,"used_credits":1615,"monthly_limit":2000,"utilization":80.75,"currency":"USD","decimal_places":2}}
    """
    let data = try #require(json.data(using: .utf8))
    let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
    #expect(usage.sevenDayOpus?.utilization == 88.0)
    let extra = try #require(usage.extraUsage?.model)
    #expect(!extra.isEnabled)
    #expect(extra.usedAmount == 16.15)
    #expect(extra.limitAmount == 20.0)
    #expect(extra.percentUsed == 80.75)
    #expect(extra.hasSpend)
  }

  @Test func toleratesNullUtilizationWithoutFailingDecode() throws {
    let json = """
    {"five_hour":{"utilization":null,"resets_at":null},"seven_day":{"utilization":61.0}}
    """
    let data = try #require(json.data(using: .utf8))
    let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
    #expect(usage.fiveHour?.utilization == nil)
    #expect(usage.sevenDay?.utilization == 61.0)
  }

  @Test func retryAfterParsesDeltaSeconds() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let response = try #require(HTTPURLResponse(
      url: URL(string: "https://api.anthropic.com")!,
      statusCode: 429,
      httpVersion: nil,
      headerFields: ["Retry-After": "120"]
    ))
    let date = OAuthPipeline.retryAfterDate(from: response, now: now)
    #expect(date == now.addingTimeInterval(120))
  }

  @Test func retryAfterAbsentReturnsNil() throws {
    let response = try #require(HTTPURLResponse(
      url: URL(string: "https://api.anthropic.com")!,
      statusCode: 429,
      httpVersion: nil,
      headerFields: [:]
    ))
    #expect(OAuthPipeline.retryAfterDate(from: response, now: Date()) == nil)
  }
}
