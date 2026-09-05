import Darwin
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

    @Test func ensureRefreshIntervalRejectsNonfiniteNumberWithoutTrapping() {
        var settings: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": "echo test",
                "refreshInterval": Double.infinity,
            ] as [String: Any]
        ]

        #expect(StatuslineBridge.ensureRefreshInterval(in: &settings))
        let statusLine = settings["statusLine"] as? [String: Any]
        #expect(statusLine?["refreshInterval"] as? Int == 1)
    }

    @Test func boundedIntegerConversionRejectsExtremeValues() {
        #expect(StatuslineBridge.boundedInt(Double.nan) == nil)
        #expect(StatuslineBridge.boundedInt(Double.infinity) == nil)
        #expect(StatuslineBridge.boundedInt(-Double.infinity) == nil)
        #expect(StatuslineBridge.boundedInt(Double.greatestFiniteMagnitude) == nil)
        #expect(StatuslineBridge.boundedInt(-12.9) == -12)
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

    @Test func readDataDropsOutOfRangeIntegerCounters() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("statusline.json")
        let json = """
            {
              "rate_limits": { "five_hour": { "used_percentage": 25 } },
              "cost": {
                "total_lines_added": 1.7976931348623157e308,
                "total_lines_removed": -1.7976931348623157e308
              }
            }
            """
        try Data(json.utf8).write(to: file)

        let payload = try StatuslineBridge.readPayload(from: file)
        #expect(payload?.codeLinesAdded == nil)
        #expect(payload?.codeLinesRemoved == nil)
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

    @Test func mergePayloadsBreaksEqualCaptureTimesDeterministically() throws {
        func payload(id: String, cost: Double) -> StatuslineBridge.StatuslinePayload {
            StatuslineBridge.StatuslinePayload(
                fiveHour: nil, sevenDay: nil, sessionId: id, sessionName: nil, cwd: nil,
                modelId: nil, modelDisplayName: nil, totalCostUsd: cost,
                totalApiDurationMs: nil, codeLinesAdded: nil, codeLinesRemoved: nil,
                cliVersion: nil, capturedAt: Date(timeIntervalSince1970: 100))
        }
        let a = payload(id: "a", cost: 1)
        let b = payload(id: "b", cost: 2)
        #expect(try #require(StatuslineBridge.mergePayloads([a, b])).sessionId == "b")
        #expect(try #require(StatuslineBridge.mergePayloads([b, a])).sessionId == "b")
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
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
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

    /// Turning the statusline source off must take the snippet back out of every
    /// config dir — otherwise Claude Code keeps writing session files forever with
    /// no in-app way to undo it. Reconciling runs on every poll, so the second call
    /// must be a no-op rather than repeated writes.
    @Test func uninstallRestoresUserCommandAndIsIdempotent() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let owned = base.appendingPathComponent("owned", isDirectory: true)
        let shared = base.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: owned, withIntermediateDirectories: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"my.sh"}}"#.utf8)
            .write(to: shared.appendingPathComponent("settings.json"))
        defer { try? fm.removeItem(at: base) }

        try StatuslineBridge.install(configDirs: [owned, shared])
        #expect(try StatuslineBridge.uninstall(configDirs: [owned, shared]))

        func settings(in dir: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: dir.appendingPathComponent("settings.json"))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        // We owned the whole command in `owned`, so the key goes away entirely.
        #expect(try settings(in: owned)["statusLine"] == nil)
        // The user's own command survives in `shared`.
        let restored = try #require(
            (try settings(in: shared)["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(restored == "my.sh")

        // Already clean → nothing to do, nothing written.
        #expect(try StatuslineBridge.uninstall(configDirs: [owned, shared]) == false)
    }

    @Test func installSkipsInvalidSettingsButStillInstallsOthers() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
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

    @Test func uninstallReportsChangesMadeBeforeAnotherDirectoryFails() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let good = base.appendingPathComponent("good", isDirectory: true)
        let bad = base.appendingPathComponent("bad", isDirectory: true)
        try fm.createDirectory(at: good, withIntermediateDirectories: true)
        try fm.createDirectory(at: bad, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let goodSettings: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": StatuslineBridge.bridgeSnippet + " > /dev/null",
            ]
        ]
        try JSONSerialization.data(withJSONObject: goodSettings)
            .write(to: good.appendingPathComponent("settings.json"))
        try Data("{ not json".utf8).write(to: bad.appendingPathComponent("settings.json"))

        do {
            _ = try StatuslineBridge.uninstall(configDirs: [good, bad])
            Issue.record("Expected the malformed settings file to throw")
        } catch let error as StatuslineBridge.UninstallError {
            #expect(error.didChange)
        } catch {
            Issue.record("Expected StatuslineBridge.UninstallError, got \(error)")
        }

        let data = try Data(contentsOf: good.appendingPathComponent("settings.json"))
        let settings = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(settings["statusLine"] == nil)
    }

    @Test func directoryCreationFailureIsSurfaced() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        #expect(throws: (any Error).self) {
            try StatuslineBridge.ensureDirectory(at: root.appendingPathComponent("sessions"))
        }
    }

    // MARK: - Grouped reads (per-account, never blended)

    @Test func readDataGroupedBucketsByAccountWithoutBlending() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
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
        let root = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // A flat file directly under the sessions root (the pre-account layout).
        let json = #"{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1900000000}}}"#
        try Data(json.utf8).write(to: root.appendingPathComponent("oldsession.json"))

        let groups = StatuslineBridge.readDataGrouped(
            sessionsRoot: root, legacyFile: nil, maxAge: 600)
        #expect(groups[StatuslineBridge.defaultAccountKey]?.fiveHour?.usedPercentage == 42)
    }

    @Test func statuslineReadsIgnoreFIFOWithoutBlocking() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fifo = root.appendingPathComponent("session.json")
        let result = fifo.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) }
        #expect(result == 0)

        let clock = ContinuousClock()
        let start = clock.now
        #expect(
            !StatuslineBridge.isDataFresh(
                sessionsRoot: root, legacyFile: fifo, maxAge: 600))
        #expect(
            StatuslineBridge.readDataGrouped(
                sessionsRoot: root, legacyFile: fifo, maxAge: 600
            ).isEmpty)
        #expect(try StatuslineBridge.readPayload(from: fifo) == nil)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func statuslineReadsDoNotFollowSymbolicLinks() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("sessions", isDirectory: true)
        let targetAccount = base.appendingPathComponent("target-account", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetAccount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let json =
            #"{"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":1900000000}}}"#
        let targetFile = targetAccount.appendingPathComponent("target.json")
        try Data(json.utf8).write(to: targetFile)

        let linkedFile = root.appendingPathComponent("linked.json")
        let linkedAccount = root.appendingPathComponent("linked-account", isDirectory: true)
        let linkedLegacy = base.appendingPathComponent("legacy.json")
        try fm.createSymbolicLink(at: linkedFile, withDestinationURL: targetFile)
        try fm.createSymbolicLink(at: linkedAccount, withDestinationURL: targetAccount)
        try fm.createSymbolicLink(at: linkedLegacy, withDestinationURL: targetFile)

        #expect(
            !StatuslineBridge.isDataFresh(
                sessionsRoot: root, legacyFile: linkedLegacy, maxAge: 600))
        #expect(
            StatuslineBridge.readDataGrouped(
                sessionsRoot: root, legacyFile: linkedLegacy, maxAge: 600
            ).isEmpty)
        #expect(try StatuslineBridge.readPayload(from: linkedFile) == nil)
    }

    @Test func statuslineReadsRejectSymbolicLinkRoot() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let targetRoot = base.appendingPathComponent("target-sessions", isDirectory: true)
        let targetAccount = targetRoot.appendingPathComponent("claude", isDirectory: true)
        let linkedRoot = base.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: targetAccount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let json =
            #"{"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":1900000000}}}"#
        try Data(json.utf8).write(to: targetAccount.appendingPathComponent("target.json"))
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: targetRoot)

        #expect(
            !StatuslineBridge.isDataFresh(
                sessionsRoot: linkedRoot, legacyFile: nil, maxAge: 600))
        #expect(
            StatuslineBridge.readDataGrouped(
                sessionsRoot: linkedRoot, legacyFile: nil, maxAge: 600
            ).isEmpty)
    }

    @Test func statuslineReadsRejectOversizedPayloads() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let file = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: 1_048_577).write(to: file)

        #expect(
            !StatuslineBridge.isDataFresh(
                sessionsRoot: root, legacyFile: nil, maxAge: 600))
        #expect(
            StatuslineBridge.readDataGrouped(
                sessionsRoot: root, legacyFile: nil, maxAge: 600
            ).isEmpty)
        #expect(try StatuslineBridge.readPayload(from: file) == nil)
    }

    @Test func statuslineReadsRejectImplausiblyFuturePayloads() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let sessions = base.appendingPathComponent("sessions/claude", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let json = #"{"rate_limits":{"five_hour":{"used_percentage":99}}}"#
        let accountFile = sessions.appendingPathComponent("future.json")
        let legacyFile = base.appendingPathComponent("statusline.json")
        try Data(json.utf8).write(to: accountFile)
        try Data(json.utf8).write(to: legacyFile)
        let future = Date().addingTimeInterval(24 * 60 * 60)
        try fm.setAttributes([.modificationDate: future], ofItemAtPath: accountFile.path)
        try fm.setAttributes([.modificationDate: future], ofItemAtPath: legacyFile.path)

        let sessionsRoot = base.appendingPathComponent("sessions", isDirectory: true)
        #expect(
            !StatuslineBridge.isDataFresh(
                sessionsRoot: sessionsRoot, legacyFile: legacyFile, maxAge: 600))
        #expect(
            StatuslineBridge.readDataGrouped(
                sessionsRoot: sessionsRoot, legacyFile: legacyFile, maxAge: 600
            ).isEmpty)
    }

    @Test func productionReadsRejectLinkedDataRoot() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let external = base.appendingPathComponent("external", isDirectory: true)
        let account = external.appendingPathComponent("sessions/claude", isDirectory: true)
        let linkedDataRoot = base.appendingPathComponent(".claude-meter", isDirectory: true)
        try fm.createDirectory(at: account, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let json = #"{"rate_limits":{"five_hour":{"used_percentage":99}}}"#
        try Data(json.utf8).write(to: account.appendingPathComponent("outside.json"))
        try Data(json.utf8).write(to: external.appendingPathComponent("statusline.json"))
        try fm.createSymbolicLink(at: linkedDataRoot, withDestinationURL: external)

        #expect(!StatuslineBridge.isDataFresh(dataRoot: linkedDataRoot, maxAge: 600))
        #expect(
            StatuslineBridge.readDataGrouped(dataRoot: linkedDataRoot, maxAge: 600).isEmpty)
    }

    @Test func purgeSessionDataRemovesOnlyManagedFiles() throws {
        let fm = FileManager.default
        let dataRoot = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let sessions = dataRoot.appendingPathComponent("sessions", isDirectory: true)
        let account = sessions.appendingPathComponent("claude", isDirectory: true)
        try fm.createDirectory(at: account, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dataRoot) }

        let accountFile = account.appendingPathComponent("account.json")
        let flatFile = sessions.appendingPathComponent("flat.json")
        let legacyFile = dataRoot.appendingPathComponent("statusline.json")
        try Data("account".utf8).write(to: accountFile)
        try Data("flat".utf8).write(to: flatFile)
        try Data("legacy".utf8).write(to: legacyFile)

        StatuslineBridge.purgeSessionData(dataRoot: dataRoot)

        #expect(!fm.fileExists(atPath: accountFile.path))
        #expect(!fm.fileExists(atPath: flatFile.path))
        #expect(!fm.fileExists(atPath: legacyFile.path))
        #expect(fm.fileExists(atPath: sessions.path))
        #expect(fm.fileExists(atPath: account.path))
    }

    @Test func purgeSessionDataRejectsLinkedDataRoot() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let external = base.appendingPathComponent("external", isDirectory: true)
        let account = external.appendingPathComponent("sessions/claude", isDirectory: true)
        let linkedDataRoot = base.appendingPathComponent(".claude-meter", isDirectory: true)
        try fm.createDirectory(at: account, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let sessionFile = account.appendingPathComponent("outside.json")
        let legacyFile = external.appendingPathComponent("statusline.json")
        try Data("outside".utf8).write(to: sessionFile)
        try Data("legacy".utf8).write(to: legacyFile)
        try fm.createSymbolicLink(at: linkedDataRoot, withDestinationURL: external)

        StatuslineBridge.purgeSessionData(dataRoot: linkedDataRoot)

        #expect(fm.fileExists(atPath: sessionFile.path))
        #expect(fm.fileExists(atPath: legacyFile.path))
        #expect(fm.fileExists(atPath: linkedDataRoot.path))
    }

    @Test func purgeSessionDataStopsWhenDataRootIsReplaced() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let dataRoot = base.appendingPathComponent(".claude-meter", isDirectory: true)
        let account = dataRoot.appendingPathComponent("sessions/claude", isDirectory: true)
        let external = base.appendingPathComponent("external", isDirectory: true)
        let externalAccount = external.appendingPathComponent("sessions/claude", isDirectory: true)
        try fm.createDirectory(at: account, withIntermediateDirectories: true)
        try fm.createDirectory(at: externalAccount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let originalFile = account.appendingPathComponent("old.json")
        let externalFile = externalAccount.appendingPathComponent("outside.json")
        try Data("old".utf8).write(to: originalFile)
        try Data("outside".utf8).write(to: externalFile)
        let displaced = base.appendingPathComponent("displaced", isDirectory: true)
        var didSwap = false

        StatuslineBridge.clearManagedSubdirectory(
            named: "sessions",
            in: dataRoot,
            beforeUnlink: { _, _ in
                guard !didSwap else { return }
                didSwap = true
                try? fm.moveItem(at: dataRoot, to: displaced)
                try? fm.createSymbolicLink(at: dataRoot, withDestinationURL: external)
            })

        #expect(didSwap)
        #expect(
            try fm.destinationOfSymbolicLink(atPath: dataRoot.path) == external.path)
        #expect(
            fm.fileExists(
                atPath: displaced.appendingPathComponent("sessions/claude/old.json").path))
        #expect(fm.fileExists(atPath: externalFile.path))
    }

    @Test func purgeSessionDataUsesOneAnchorAcrossAllCleanup() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let dataRoot = base.appendingPathComponent(".claude-meter", isDirectory: true)
        let originalAccount = dataRoot.appendingPathComponent("sessions/claude", isDirectory: true)
        let replacement = base.appendingPathComponent("replacement", isDirectory: true)
        let replacementAccount = replacement.appendingPathComponent(
            "sessions/claude", isDirectory: true)
        try fm.createDirectory(at: originalAccount, withIntermediateDirectories: true)
        try fm.createDirectory(at: replacementAccount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let originalSession = originalAccount.appendingPathComponent("old.json")
        let originalLegacy = dataRoot.appendingPathComponent("statusline.json")
        try Data("old".utf8).write(to: originalSession)
        try Data("old legacy".utf8).write(to: originalLegacy)
        try Data("outside".utf8).write(
            to: replacementAccount.appendingPathComponent("outside.json"))
        try Data("outside legacy".utf8).write(
            to: replacement.appendingPathComponent("statusline.json"))
        let displaced = base.appendingPathComponent("displaced", isDirectory: true)
        var didSwap = false

        StatuslineBridge.purgeSessionData(
            dataRoot: dataRoot,
            beforeUnlink: { _, _ in
                guard !didSwap else { return }
                didSwap = true
                try? fm.moveItem(at: dataRoot, to: displaced)
                try? fm.moveItem(at: replacement, to: dataRoot)
            })

        #expect(didSwap)
        #expect(
            fm.fileExists(
                atPath: displaced.appendingPathComponent("sessions/claude/old.json").path))
        #expect(fm.fileExists(atPath: displaced.appendingPathComponent("statusline.json").path))
        #expect(
            fm.fileExists(
                atPath: dataRoot.appendingPathComponent("sessions/claude/outside.json").path))
        #expect(fm.fileExists(atPath: dataRoot.appendingPathComponent("statusline.json").path))
    }
}
