import Darwin
import Foundation
import Testing

@testable import ClaudeMeterCore

private let fixedDate = Date(timeIntervalSince1970: 1_782_108_000)  // 2026-06-22T06:00:00Z

private func makeSnapshot(sessionPercent: Double = 25, weekPercent: Double = 30)
    -> ClaudeUsageSnapshot
{
    ClaudeUsageSnapshot(
        parserVersion: "0.1.0",
        createdAt: fixedDate,
        source: SourceInfo(cliPath: "/opt/homebrew/bin/claude", command: "claude status"),
        limits: LimitInfo(
            currentSession: LimitWindow(
                percentUsed: sessionPercent,
                resetsAt: fixedDate.addingTimeInterval(3000),
                rawResetText: "2:50pm (Asia/Kuala_Lumpur)"
            ),
            currentWeekAllModels: LimitWindow(
                percentUsed: weekPercent,
                resetsAt: fixedDate.addingTimeInterval(5 * 86400),
                rawResetText: "Jun 27 at 3pm (Asia/Kuala_Lumpur)"
            )
        ),
        state: SnapshotState(status: .ok, severity: .normal)
    )
}

@Suite("SnapshotStore")
final class SnapshotStoreTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeMeterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> SnapshotStore {
        let dir = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SnapshotStore(directory: dir)
    }

    // MARK: - Read/write roundtrip

    @Test("Writes and reads back an identical snapshot")
    func roundtrip() throws {
        let store = try makeStore()
        let original = makeSnapshot()

        try store.writeLatest(original)
        let recovered = try store.readLatest()

        #expect(recovered != nil)
        #expect(recovered == original)
    }

    @Test("Older snapshots retain quota and live extra usage while ignoring removed analytics")
    func olderSnapshotPreservesQuota() throws {
        let store = try makeStore()
        var original = makeSnapshot()
        original.lastSuccessfulPollAt = fixedDate
        original.account = AccountInfo(plan: "Max")
        original.limits.extraUsage = ExtraUsage(
            isEnabled: true, usedCredits: 1250, monthlyLimit: 5000, currency: "USD")
        try store.writeLatest(original)
        let url = store.directory.appending(path: "current.json")
        var legacy = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        legacy["models"] = [["name": "old-model", "costUsd": 12, "inputTokens": 100]]
        legacy["costObservation"] = ["scannedAt": "2026-06-22T06:00:00Z", "isPartial": true]
        var session: [String: Any] = [
            "activeModel": "Claude", "cwd": "/old/path", "id": "old-session",
        ]
        session["totalCostUsd"] = 12
        session["totalApiDurationSeconds"] = 30
        session["codeLinesAdded"] = 10
        session["codeLinesRemoved"] = 5
        legacy["session"] = session
        try JSONSerialization.data(withJSONObject: legacy).write(to: url, options: .atomic)

        let recovered = try #require(try store.readLatest())
        #expect(recovered == original)
        #expect(recovered.limits.extraUsage?.usedAmount == 12.5)
        try store.writeLatest(recovered)
        let rewritten = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(rewritten["models"] == nil)
        #expect(rewritten["costObservation"] == nil)
        #expect(rewritten["session"] == nil)
    }

    @Test("Legacy local observations are stale at the persistence boundary")
    func legacyStatuslineSnapshotIsNeverCurrentOAuth() throws {
        let store = try makeStore()
        var snapshot = makeSnapshot()
        snapshot.parserVersion = "statusline-1.0"
        snapshot.source = SourceInfo(cliPath: "statusline-bridge", command: "capture")
        try store.writeLatest(snapshot)
        let restored = try #require(try store.readLatest())
        #expect(restored.state.isStale)
        #expect(restored.limits == snapshot.limits)
        snapshot.parserVersion = "oauth-api-1.0"
        snapshot.source = SourceInfo(cliPath: "api.anthropic.com", command: "GET /api/oauth/usage")
        try store.writeLatest(snapshot)
        #expect(try store.readLatest()?.state.isStale == false)
    }

    @Test("Rejects unsafe dates before ISO-8601 formatting")
    func rejectsUnsafeDatesBeforeFormatting() throws {
        let store = try makeStore()
        let unsafeDate = Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude)

        var snapshot = makeSnapshot()
        snapshot.createdAt = unsafeDate
        #expect(throws: EncodingError.self) {
            try store.writeLatest(snapshot)
        }

        #expect(throws: EncodingError.self) {
            try store.writeLastError(LastErrorRecord(occurredAt: unsafeDate, message: "fail"))
        }
    }

    @Test("readLatest returns nil when no file exists")
    func readMissingReturnsNil() throws {
        let store = try makeStore()
        #expect(try store.readLatest() == nil)
    }

    @Test("A wedged filesystem operation trips a per-store circuit breaker")
    func boundedIOTimeout() throws {
        let io = BoundedSnapshotIO()
        let started = Date()

        #expect(throws: SnapshotStoreIOError.self) {
            try io.perform(operation: "test", timeout: 0.02) {
                Thread.sleep(forTimeInterval: 0.5)
                return true
            }
        }
        #expect(Date().timeIntervalSince(started) < 0.25)

        do {
            _ = try io.perform(operation: "test", timeout: 1) {
                return true
            }
            Issue.record("expected the circuit breaker to reject later I/O")
        } catch let error as SnapshotStoreIOError {
            #expect(error == .disabledAfterTimeout)
        } catch {
            Issue.record("expected SnapshotStoreIOError, got \(error)")
        }
    }

    @Test("Overwrites an existing snapshot atomically")
    func overwrite() throws {
        let store = try makeStore()

        try store.writeLatest(makeSnapshot(sessionPercent: 25))
        try store.writeLatest(makeSnapshot(sessionPercent: 84))

        let recovered = try store.readLatest()
        #expect(recovered?.limits.currentSession.percentUsed == 84)
    }

    // MARK: - Last error

    @Test("Writes and reads last error record")
    func lastErrorRoundtrip() throws {
        let store = try makeStore()
        let record = LastErrorRecord(occurredAt: fixedDate, message: "CLI timed out")

        try store.writeLastError(record)
        let recovered = try store.readLastError()

        #expect(recovered == record)
    }

    @Test("Last errors are sanitized at the persistence boundary")
    func lastErrorIsSanitized() throws {
        let store = try makeStore()
        try store.writeLastError(
            LastErrorRecord(message: "token for user@example.com at /Users/alice/.claude"))

        let recovered = try #require(try store.readLastError())
        #expect(!recovered.message.contains("user@example.com"))
        #expect(!recovered.message.contains("/Users/alice"))
    }

    @Test("clearLastError removes the error file")
    func clearLastError() throws {
        let store = try makeStore()
        try store.writeLastError(LastErrorRecord(message: "fail"))
        try store.clearLastError()
        #expect(try store.readLastError() == nil)
    }

    @Test("readLastError returns nil when no error file exists")
    func readLastErrorMissing() throws {
        let store = try makeStore()
        #expect(try store.readLastError() == nil)
    }

    // MARK: - JSON validity

    @Test("Written file is valid UTF-8 JSON")
    func writtenFileIsJSON() throws {
        let store = try makeStore()
        try store.writeLatest(makeSnapshot())

        let currentURL = store.directory.appending(path: "current.json")
        let data = try Data(contentsOf: currentURL)
        let json = try JSONSerialization.jsonObject(with: data)
        #expect(json is [String: Any])
    }

    @Test("JSON contains schemaVersion field")
    func containsSchemaVersion() throws {
        let store = try makeStore()
        try store.writeLatest(makeSnapshot())

        let currentURL = store.directory.appending(path: "current.json")
        let data = try Data(contentsOf: currentURL)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["schemaVersion"] as? Int == 1)
    }

    // MARK: - Corrupt / missing data

    @Test("Throws on corrupt JSON")
    func corruptJSON() throws {
        let store = try makeStore()
        let currentURL = store.directory.appending(path: "current.json")

        try "not valid json {{{".data(using: .utf8)!.write(to: currentURL)

        #expect(throws: (any Error).self) {
            try store.readLatest()
        }
    }

    @Test("Throws on truncated JSON")
    func truncatedJSON() throws {
        let store = try makeStore()
        try store.writeLatest(makeSnapshot())

        let currentURL = store.directory.appending(path: "current.json")
        let data = try Data(contentsOf: currentURL)

        try data.prefix(50).write(to: currentURL)

        #expect(throws: (any Error).self) {
            try store.readLatest()
        }
    }

    @Test("Every durable read rejects an oversized file before allocation")
    func oversizedDurableFilesAreRejected() throws {
        let store = try makeStore()
        let readers: [(String, () throws -> Void)] = [
            ("current.json", { _ = try store.readLatest() }),
            ("last-error.json", { _ = try store.readLastError() }),
        ]

        for (filename, read) in readers {
            let url = store.directory.appendingPathComponent(filename)
            #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(SnapshotStore.maximumReadBytes + 1))
            try handle.close()
            defer { try? FileManager.default.removeItem(at: url) }

            do {
                try read()
                Issue.record("Expected \(filename) to reject an oversized file")
            } catch let error as SnapshotStoreIOError {
                #expect(
                    error
                        == .storedFileTooLarge(
                            maximumByteCount: SnapshotStore.maximumReadBytes))
            } catch {
                Issue.record("Expected a SnapshotStoreIOError for \(filename), got \(error)")
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    @Test("Every durable read rejects a FIFO without blocking")
    func durableReadsRejectFIFO() throws {
        let store = try makeStore()
        let readers: [(String, () throws -> Void)] = [
            ("current.json", { _ = try store.readLatest() }),
            ("last-error.json", { _ = try store.readLastError() }),
        ]

        for (filename, read) in readers {
            let url = store.directory.appendingPathComponent(filename)
            let result = url.path.withCString { Darwin.mkfifo($0, 0o600) }
            #expect(result == 0)
            defer { try? FileManager.default.removeItem(at: url) }
            let startedAt = Date()

            do {
                try read()
                Issue.record("Expected \(filename) to reject a FIFO")
            } catch let error as SnapshotStoreIOError {
                #expect(error == .invalidStoredFile)
            } catch {
                Issue.record("Expected a SnapshotStoreIOError for \(filename), got \(error)")
            }
            #expect(Date().timeIntervalSince(startedAt) < 0.5)
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Directory

    @Test("applicationSupport(in:) creates ClaudeMeter directory hermetically")
    func appSupportDir() throws {
        let store = try SnapshotStore.applicationSupport(in: root)
        #expect(store.directory.lastPathComponent == "ClaudeMeter")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.directory.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test(
        "Legacy import keeps the newest observation and runs once", arguments: [nil, -60.0, 0, 60])
    func importsLegacySnapshot(currentOffset: Double?) throws {
        let suite = "LegacySnapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try SnapshotStore.applicationSupport(
            in: root.appending(path: "Application Support"))
        let legacyDirectory = root.appending(
            path:
                "Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter"
        )
        try FileManager.default.createDirectory(
            at: legacyDirectory, withIntermediateDirectories: true)
        let legacy = SnapshotStore(directory: legacyDirectory)
        var previous = makeSnapshot(sessionPercent: 35)
        previous.lastSuccessfulPollAt = fixedDate
        try legacy.writeLatest(previous)
        let legacyBytes = try Data(contentsOf: legacyDirectory.appending(path: "current.json"))
        var current: ClaudeUsageSnapshot?
        if let currentOffset {
            var snapshot = makeSnapshot(sessionPercent: 75)
            snapshot.lastSuccessfulPollAt = fixedDate.addingTimeInterval(currentOffset)
            // Rewrite time must not make an older usage observation win.
            snapshot.createdAt = fixedDate.addingTimeInterval(3600)
            try store.writeLatest(snapshot)
            current = snapshot
        }

        try store.importLegacyAppGroupSnapshotIfNeeded(home: root, defaults: defaults)
        let expected = currentOffset.map { $0 >= 0 } == true ? current : previous
        #expect(try store.readLatest() == expected)
        #expect(defaults.bool(forKey: "didImportLegacyAppGroupSnapshot.v1"))
        #expect(
            try Data(contentsOf: legacyDirectory.appending(path: "current.json")) == legacyBytes)

        previous.lastSuccessfulPollAt = fixedDate.addingTimeInterval(7200)
        try legacy.writeLatest(previous)
        try store.importLegacyAppGroupSnapshotIfNeeded(home: root, defaults: defaults)
        #expect(try store.readLatest() == expected)
        #expect(
            !FileManager.default.fileExists(
                atPath: store.directory.appending(path: "main-meter.json").path))
    }

    @Test("Missing legacy data does not create a shared container")
    func missingLegacySnapshot() throws {
        let suite = "MissingLegacySnapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try makeStore()
        try store.importLegacyAppGroupSnapshotIfNeeded(home: root, defaults: defaults)
        #expect(try store.readLatest() == nil)
        #expect(defaults.bool(forKey: "didImportLegacyAppGroupSnapshot.v1"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Library").path))
    }

    @Test("A malformed legacy snapshot preserves local data and can be retried")
    func malformedLegacySnapshot() throws {
        let suite = "MalformedLegacySnapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try makeStore()
        let original = makeSnapshot()
        try store.writeLatest(original)
        let legacyDirectory = root.appending(
            path:
                "Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter"
        )
        try FileManager.default.createDirectory(
            at: legacyDirectory, withIntermediateDirectories: true)
        let url = legacyDirectory.appending(path: "current.json")
        let malformed = Data("invalid JSON".utf8)
        try malformed.write(to: url)

        #expect(throws: DecodingError.self) {
            try store.importLegacyAppGroupSnapshotIfNeeded(home: root, defaults: defaults)
        }
        #expect(try store.readLatest() == original)
        #expect(try Data(contentsOf: url) == malformed)
        #expect(!defaults.bool(forKey: "didImportLegacyAppGroupSnapshot.v1"))

        var recovered = makeSnapshot(sessionPercent: 55)
        recovered.lastSuccessfulPollAt = fixedDate.addingTimeInterval(60)
        try SnapshotStore(directory: legacyDirectory).writeLatest(recovered)
        try store.importLegacyAppGroupSnapshotIfNeeded(home: root, defaults: defaults)
        #expect(try store.readLatest() == recovered)
        #expect(defaults.bool(forKey: "didImportLegacyAppGroupSnapshot.v1"))
    }

    @Test("A failed destination write does not complete the legacy import")
    func legacyImportWriteFailure() throws {
        let suite = "FailedLegacySnapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyDirectory = root.appending(
            path:
                "Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter"
        )
        try FileManager.default.createDirectory(
            at: legacyDirectory, withIntermediateDirectories: true)
        let original = makeSnapshot()
        try SnapshotStore(directory: legacyDirectory).writeLatest(original)
        let destination = root.appending(path: "missing-destination")
        let store = SnapshotStore(directory: destination)
        #expect(throws: (any Error).self) {
            try store.importLegacyAppGroupSnapshotIfNeeded(home: root, defaults: defaults)
        }
        #expect(!defaults.bool(forKey: "didImportLegacyAppGroupSnapshot.v1"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try store.importLegacyAppGroupSnapshotIfNeeded(home: root, defaults: defaults)
        #expect(try store.readLatest() == original)
    }

    // MARK: - Dates survive encode/decode

    @Test("Reset dates survive JSON roundtrip")
    func datesRoundtrip() throws {
        let store = try makeStore()
        let snap = makeSnapshot()
        let originalResetsAt = snap.limits.currentSession.resetsAt!

        try store.writeLatest(snap)
        let recovered = try #require(try store.readLatest())

        let delta = abs(
            recovered.limits.currentSession.resetsAt!.timeIntervalSince(originalResetsAt))
        #expect(delta < 1.0)
    }
}
