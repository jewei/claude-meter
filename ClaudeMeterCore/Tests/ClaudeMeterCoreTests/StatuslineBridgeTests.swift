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

  @Test func readDataAcceptsIntegerPercentagesAndResetTimes() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("statusline.json")
    let json = """
    {
      "rate_limits": {
        "five_hour": {
          "used_percentage": 25,
          "resets_at": 1770000000
        }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: file)

    let payload = try #require(StatuslineBridge.readData(from: file))
    #expect(payload.fiveHour?.usedPercentage == 25)
    #expect(payload.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1770000000))
  }

  @Test func settingsParserAllowsMissingFileButRejectsInvalidJSON() throws {
    let missing = try StatuslineBridge.parseSettingsDataForTesting(nil)
    #expect(missing.isEmpty)

    do {
      _ = try StatuslineBridge.parseSettingsDataForTesting(Data("{".utf8))
      Issue.record("Expected invalid settings JSON to throw")
    } catch {}
  }

  @Test func settingsParserRejectsNonObjectRoot() throws {
    do {
      _ = try StatuslineBridge.parseSettingsDataForTesting(Data("[]".utf8))
      Issue.record("Expected non-object settings JSON to throw")
    } catch {}
  }
}
