import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite("StatuslineBridge")
struct StatuslineBridgeTests {
  @Test func ensureRefreshIntervalSetsOneSecond() {
    var settings: [String: Any] = [
      "statusLine": [
        "type": "command",
        "command": "echo test",
      ] as [String: Any],
    ]
    #expect(StatuslineBridge.ensureRefreshInterval(in: &settings))
    let statusLine = settings["statusLine"] as? [String: Any]
    #expect(statusLine?["refreshInterval"] as? Int == 1)
  }

  @Test func ensureRefreshIntervalIsIdempotent() {
    var settings: [String: Any] = [
      "statusLine": [
        "type": "command",
        "command": "echo test",
        "refreshInterval": 1,
      ] as [String: Any],
    ]
    #expect(!StatuslineBridge.ensureRefreshInterval(in: &settings))
  }

  @Test func ensureRefreshIntervalSkipsMissingStatusLine() {
    var settings: [String: Any] = [:]
    #expect(!StatuslineBridge.ensureRefreshInterval(in: &settings))
  }
}
