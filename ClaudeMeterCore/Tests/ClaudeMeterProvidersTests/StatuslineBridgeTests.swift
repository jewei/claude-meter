import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("StatuslineBridge")
struct StatuslineBridgeTests {
    @Test func ensureRefreshIntervalSetsOneSecond() {
        var settings: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": "echo test",
            ] as [String: Any]
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
            ] as [String: Any]
        ]
        #expect(!StatuslineBridge.ensureRefreshInterval(in: &settings))
    }

    @Test func ensureRefreshIntervalSkipsMissingStatusLine() {
        var settings: [String: Any] = [:]
        #expect(!StatuslineBridge.ensureRefreshInterval(in: &settings))
    }

    @Test func strippedOfAnyBridgeReturnsUserCommandUnchangedWhenNoBridge() {
        #expect(
            StatuslineBridge.strippedOfAnyBridge(from: "my-statusline.sh") == "my-statusline.sh")
    }

    @Test func strippedOfAnyBridgeRecoversUserCommand() {
        let cmd = StatuslineBridge.bridgeSnippet + " | my-statusline.sh"
        #expect(StatuslineBridge.strippedOfAnyBridge(from: cmd) == "my-statusline.sh")
    }

    @Test func strippedOfAnyBridgeReturnsEmptyForBridgeOnly() {
        #expect(
            StatuslineBridge.strippedOfAnyBridge(
                from: StatuslineBridge.bridgeSnippet + " > /dev/null") == "")
    }

    @Test func strippedOfAnyBridgeCollapsesAccumulatedDuplicates() {
        // Earlier versions could prepend the bridge repeatedly; migration must collapse
        // the whole chain back to the user's real command.
        let legacy = StatuslineBridge.legacyBridgeSnippets[0]
        let chain =
            Array(repeating: legacy, count: 5).joined(separator: " | ")
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
        #expect(payload?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_770_000_000))
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
        #expect(payload?.sevenDayOpus?.resetsAt == Date(timeIntervalSince1970: 1_770_500_000))
    }

    @Test func mergePayloadsPicksFreshestWindowAcrossSessions() {
        func payload(
            fiveHourPct: Double, fiveHourReset: TimeInterval,
            sevenDayPct: Double, capturedAt: Date
        ) -> StatuslineBridge.StatuslinePayload {
            StatuslineBridge.StatuslinePayload(
                fiveHour: .init(
                    usedPercentage: fiveHourPct,
                    resetsAt: Date(timeIntervalSince1970: fiveHourReset)),
                sevenDay: .init(
                    usedPercentage: sevenDayPct,
                    resetsAt: Date(timeIntervalSince1970: 1_782_543_600)),
                sessionId: "s", sessionName: nil, cwd: nil, modelId: nil, modelDisplayName: nil,
                totalCostUsd: nil, totalApiDurationMs: nil, codeLinesAdded: nil,
                codeLinesRemoved: nil,
                cliVersion: nil, capturedAt: capturedAt
            )
        }

        // Stale sessions report old five-hour windows (smaller reset) and lower weekly usage.
        let stockhound = payload(
            fiveHourPct: 15, fiveHourReset: 1_782_111_000, sevenDayPct: 29,
            capturedAt: Date(timeIntervalSince1970: 100))
        let games = payload(
            fiveHourPct: 83, fiveHourReset: 1_782_214_200, sevenDayPct: 61,
            capturedAt: Date(timeIntervalSince1970: 200))
        let current = payload(
            fiveHourPct: 7, fiveHourReset: 1_782_256_200, sevenDayPct: 61,
            capturedAt: Date(timeIntervalSince1970: 300))

        let merged = StatuslineBridge.mergePayloads([stockhound, games, current])

        // Five-hour: latest reset wins (the current session), not the highest percentage.
        #expect(merged?.fiveHour?.usedPercentage == 7)
        #expect(merged?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_782_256_200))
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
                sevenDay: .init(
                    usedPercentage: sevenDayPct,
                    resetsAt: Date(timeIntervalSince1970: sevenDayReset)),
                sessionId: "s", sessionName: nil, cwd: nil, modelId: nil, modelDisplayName: nil,
                totalCostUsd: nil, totalApiDurationMs: nil, codeLinesAdded: nil,
                codeLinesRemoved: nil,
                cliVersion: nil, capturedAt: capturedAt
            )
        }

        let staleIdle = payload(
            sevenDayPct: 60, sevenDayReset: 1_780_000_000,
            capturedAt: Date(timeIntervalSince1970: 100))
        let activeFresh = payload(
            sevenDayPct: 5, sevenDayReset: 1_782_000_000,
            capturedAt: Date(timeIntervalSince1970: 200))

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

    // MARK: - Account-tagged snippet

    @Test func bridgeSnippetTagsByConfigDir() {
        // The snippet must derive the account key from CLAUDE_CONFIG_DIR and write
        // into a per-account subdir — the basis of separating accounts.
        #expect(StatuslineBridge.bridgeSnippet.contains("CLAUDE_CONFIG_DIR"))
        #expect(StatuslineBridge.bridgeSnippet.contains("sessions/$A"))
        // Mirrors ConfigDirDiscovery.accountKey: leading-dot strip + sanitize + fallback.
        #expect(StatuslineBridge.bridgeSnippet.contains("A=${A#.}"))
        // LC_ALL=C forces byte-oriented tr → byte-for-byte parity with the ASCII Swift set.
        #expect(StatuslineBridge.bridgeSnippet.contains(#"LC_ALL=C tr -cd "[:alnum:]._-""#))
    }

    @Test func strippedOfAnyBridgeMigratesPriorPerSessionSnippet() {
        // The pre-account per-session snippet is now legacyBridgeSnippets[0]; an
        // install that stacked it before the new snippet must collapse to the user
        // command (self-healing migration).
        let legacyPerSession = StatuslineBridge.legacyBridgeSnippets[0]
        let cmd = legacyPerSession + " | " + StatuslineBridge.bridgeSnippet + " | user.sh"
        #expect(StatuslineBridge.strippedOfAnyBridge(from: cmd) == "user.sh")
    }

    // MARK: - Multi-dir install

    @Test func installConfigDirsTagsEachSettingsAndPreservesUserCommand() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dirA = base.appendingPathComponent("a", isDirectory: true)
        let dirB = base.appendingPathComponent("b", isDirectory: true)
        try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        // B already has a user statusline command to preserve.
        try Data(#"{"statusLine":{"type":"command","command":"my.sh"}}"#.utf8)
            .write(to: dirB.appendingPathComponent("settings.json"))
        defer { try? fm.removeItem(at: base) }

        try StatuslineBridge.install(configDirs: [dirA, dirB])

        func command(in dir: URL) throws -> String {
            let data = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
            let obj = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let statusLine = try #require(obj["statusLine"] as? [String: Any])
            return try #require(statusLine["command"] as? String)
        }
        // Round-trips through JSON byte-exactly (catches snippet escaping bugs).
        #expect(try command(in: dirA) == StatuslineBridge.bridgeSnippet + " > /dev/null")
        #expect(try command(in: dirB) == StatuslineBridge.bridgeSnippet + " | my.sh")
    }

    @Test func installSkipsInvalidSettingsButStillInstallsOthers() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let good = base.appendingPathComponent("good", isDirectory: true)
        let bad = base.appendingPathComponent("bad", isDirectory: true)
        try fm.createDirectory(at: good, withIntermediateDirectories: true)
        try fm.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: bad.appendingPathComponent("settings.json"))
        defer { try? fm.removeItem(at: base) }

        // The bad dir surfaces an error, but the good dir is still installed.
        #expect(throws: (any Error).self) {
            try StatuslineBridge.install(configDirs: [good, bad])
        }
        let goodData = try Data(contentsOf: good.appendingPathComponent("settings.json"))
        let obj = try JSONSerialization.jsonObject(with: goodData) as? [String: Any]
        let cmd = (obj?["statusLine"] as? [String: Any])?["command"] as? String
        #expect(cmd == StatuslineBridge.bridgeSnippet + " > /dev/null")
    }

    // MARK: - Grouped reads (per-account, never blended)

    @Test func readDataGroupedBucketsByAccountWithoutBlending() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let claudeDir = root.appendingPathComponent("claude", isDirectory: true)
        let workDir = root.appendingPathComponent("claude-work", isDirectory: true)
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func write(_ dir: URL, _ name: String, pct: Int, reset: Int) throws {
            let json =
                #"{"rate_limits":{"five_hour":{"used_percentage":\#(pct),"resets_at":\#(reset)}}}"#
            try Data(json.utf8).write(to: dir.appendingPathComponent("\(name).json"))
        }
        try write(claudeDir, "s1", pct: 20, reset: 1_900_000_000)
        try write(workDir, "s2", pct: 80, reset: 1_900_000_500)

        let groups = StatuslineBridge.readDataGrouped(
            sessionsRoot: root, legacyFile: nil, maxAge: 600)
        #expect(groups.count == 2)
        #expect(groups["claude"]?.fiveHour?.usedPercentage == 20)
        #expect(groups["claude-work"]?.fiveHour?.usedPercentage == 80)
    }

    @Test func readDataGroupedBucketsLegacyFlatFilesUnderDefault() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // A flat file directly under the sessions root (the pre-account layout).
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1900000000}}}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("oldsession.json"))

        let groups = StatuslineBridge.readDataGrouped(
            sessionsRoot: root, legacyFile: nil, maxAge: 600)
        #expect(groups[StatuslineBridge.defaultAccountKey]?.fiveHour?.usedPercentage == 42)
    }
}
