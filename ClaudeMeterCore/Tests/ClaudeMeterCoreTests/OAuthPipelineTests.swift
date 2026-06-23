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
    let usage = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
    #expect(usage.fiveHour?.utilization == 81.0)
    #expect(usage.sevenDay?.utilization == 61.0)
  }
}

/// Test-only mirror of the private `UsageResponse` decode shape.
private struct OAuthUsageResponse: Decodable {
  let fiveHour: OAuthQuotaEntry?
  let sevenDay: OAuthQuotaEntry?

  enum CodingKeys: String, CodingKey {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
  }
}

private struct OAuthQuotaEntry: Decodable {
  let utilization: Double
  let resetsAt: String?

  enum CodingKeys: String, CodingKey {
    case utilization
    case resetsAt = "resets_at"
  }
}
