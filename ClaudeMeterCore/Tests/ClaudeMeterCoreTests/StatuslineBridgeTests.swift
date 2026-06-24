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

  @Test func strippedOfAnyBridgeReturnsUserCommandUnchangedWhenNoBridge() {
    #expect(StatuslineBridge.strippedOfAnyBridge(from: "my-statusline.sh") == "my-statusline.sh")
  }

  @Test func strippedOfAnyBridgeRecoversUserCommand() {
    let cmd = StatuslineBridge.bridgeSnippet + " | my-statusline.sh"
    #expect(StatuslineBridge.strippedOfAnyBridge(from: cmd) == "my-statusline.sh")
  }

  @Test func strippedOfAnyBridgeReturnsEmptyForBridgeOnly() {
    #expect(StatuslineBridge.strippedOfAnyBridge(from: StatuslineBridge.bridgeSnippet + " > /dev/null") == "")
  }

  @Test func strippedOfAnyBridgeCollapsesAccumulatedDuplicates() {
    // Earlier versions could prepend the bridge repeatedly; migration must collapse
    // the whole chain back to the user's real command.
    let legacy = StatuslineBridge.legacyBridgeSnippets[0]
    let chain = Array(repeating: legacy, count: 5).joined(separator: " | ")
      + " | " + StatuslineBridge.bridgeSnippet
      + " | user-statusline.sh"
    #expect(StatuslineBridge.strippedOfAnyBridge(from: chain) == "user-statusline.sh")
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

    let payload = try StatuslineBridge.readPayload(from: file)
    #expect(payload?.fiveHour?.usedPercentage == 25)
    #expect(payload?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1770000000))
  }

  @Test func readDataParsesOpusWeeklyWindow() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("statusline.json")
    let json = """
    {
      "rate_limits": {
        "five_hour": { "used_percentage": 25, "resets_at": 1770000000 },
        "seven_day_opus": { "used_percentage": 90, "resets_at": 1770500000 }
      }
    }
    """
    try json.data(using: .utf8)?.write(to: file)

    let payload = try StatuslineBridge.readPayload(from: file)
    #expect(payload?.sevenDayOpus?.usedPercentage == 90)
    #expect(payload?.sevenDayOpus?.resetsAt == Date(timeIntervalSince1970: 1770500000))
  }

  @Test func mergePayloadsPicksFreshestWindowAcrossSessions() {
    func payload(
      fiveHourPct: Double, fiveHourReset: TimeInterval,
      sevenDayPct: Double, capturedAt: Date
    ) -> StatuslineBridge.StatuslinePayload {
      StatuslineBridge.StatuslinePayload(
        fiveHour: .init(usedPercentage: fiveHourPct, resetsAt: Date(timeIntervalSince1970: fiveHourReset)),
        sevenDay: .init(usedPercentage: sevenDayPct, resetsAt: Date(timeIntervalSince1970: 1782543600)),
        sessionId: "s", sessionName: nil, cwd: nil, modelId: nil, modelDisplayName: nil,
        totalCostUsd: nil, totalApiDurationMs: nil, codeLinesAdded: nil, codeLinesRemoved: nil,
        cliVersion: nil, capturedAt: capturedAt
      )
    }

    // Stale sessions report old five-hour windows (smaller reset) and lower weekly usage.
    let stockhound = payload(fiveHourPct: 15, fiveHourReset: 1782111000, sevenDayPct: 29, capturedAt: Date(timeIntervalSince1970: 100))
    let games = payload(fiveHourPct: 83, fiveHourReset: 1782214200, sevenDayPct: 61, capturedAt: Date(timeIntervalSince1970: 200))
    let current = payload(fiveHourPct: 7, fiveHourReset: 1782256200, sevenDayPct: 61, capturedAt: Date(timeIntervalSince1970: 300))

    let merged = StatuslineBridge.mergePayloads([stockhound, games, current])

    // Five-hour: latest reset wins (the current session), not the highest percentage.
    #expect(merged?.fiveHour?.usedPercentage == 7)
    #expect(merged?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1782256200))
    // Weekly: latest `resets_at` wins (same as five-hour); stale idle sessions
    // after a reset must not inflate the merged percentage.
    #expect(merged?.sevenDay?.usedPercentage == 61)
  }

  @Test func mergePayloadsWeeklyPrefersLatestResetAfterRegression() {
    func payload(
      sevenDayPct: Double, sevenDayReset: TimeInterval, capturedAt: Date
    ) -> StatuslineBridge.StatuslinePayload {
      StatuslineBridge.StatuslinePayload(
        fiveHour: nil,
        sevenDay: .init(usedPercentage: sevenDayPct, resetsAt: Date(timeIntervalSince1970: sevenDayReset)),
        sessionId: "s", sessionName: nil, cwd: nil, modelId: nil, modelDisplayName: nil,
        totalCostUsd: nil, totalApiDurationMs: nil, codeLinesAdded: nil, codeLinesRemoved: nil,
        cliVersion: nil, capturedAt: capturedAt
      )
    }

    let staleIdle = payload(sevenDayPct: 60, sevenDayReset: 1_780_000_000, capturedAt: Date(timeIntervalSince1970: 100))
    let activeFresh = payload(sevenDayPct: 5, sevenDayReset: 1_782_000_000, capturedAt: Date(timeIntervalSince1970: 200))

    let merged = StatuslineBridge.mergePayloads([staleIdle, activeFresh])
    #expect(merged?.sevenDay?.usedPercentage == 5)
    #expect(merged?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_782_000_000))
  }

  @Test func mergePayloadsReturnsNilForEmptyInput() {
    #expect(StatuslineBridge.mergePayloads([]) == nil)
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
