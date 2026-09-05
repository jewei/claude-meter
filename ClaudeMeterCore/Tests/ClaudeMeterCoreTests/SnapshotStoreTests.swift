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

    @Test("Rejects unsafe dates before ISO-8601 formatting")
    func rejectsUnsafeDatesBeforeFormatting() throws {
        let store = try makeStore()
        let unsafeDate = Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude)

        var snapshot = makeSnapshot()
        snapshot.createdAt = unsafeDate
        #expect(throws: EncodingError.self) {
            try store.writeLatest(snapshot)
        }

        let reading = MainMeterReading(
            provider: .codex,
            accountID: "codex-test",
            accountLabel: "Codex",
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 10)),
            observedAt: unsafeDate)
        #expect(throws: EncodingError.self) {
            try store.writeMainMeter(reading)
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

    @Test("Writes, reads, and clears the selected main meter independently")
    func mainMeterRoundtrip() throws {
        let store = try makeStore()
        let reading = MainMeterReading(
            provider: .codex,
            accountID: "codex-work",
            accountLabel: "Work",
            plan: "Pro",
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: 42, resetsAt: fixedDate.addingTimeInterval(18_000)),
                currentWeekAllModels: LimitWindow(
                    percentUsed: 63, resetsAt: fixedDate.addingTimeInterval(604_800))),
            sessionLabel: "5h",
            weeklyLabel: "Weekly",
            observedAt: fixedDate)

        try store.writeMainMeter(reading)
        #expect(try store.readMainMeter() == reading)
        #expect(try store.readLatest() == nil)

        try store.clearMainMeter()
        #expect(try store.readMainMeter() == nil)
    }

    @Test("Widget publication loader follows shared provider, pin, revision, and clearing")
    func mainMeterPublicationLoader() throws {
        let store = try makeStore()
        let defaultsName = "MainMeterPublication-defaults-\(UUID().uuidString)"
        let sharedName = "MainMeterPublication-shared-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let shared = UserDefaults(suiteName: sharedName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            shared.removePersistentDomain(forName: sharedName)
        }
        defaults.set("claude", forKey: AppGroupConfig.mainMeterProviderKey)
        defaults.set("wrong", forKey: AppGroupConfig.codexMainMeterAccountKey)
        shared.set("codex", forKey: AppGroupConfig.mainMeterProviderKey)
        shared.set("codex-work", forKey: AppGroupConfig.codexMainMeterAccountKey)
        shared.set(7, forKey: AppGroupConfig.mainMeterRevisionKey)
        let reading = MainMeterReading(
            provider: .codex,
            accountID: "codex-work",
            accountLabel: "Work",
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 42)),
            observedAt: fixedDate,
            selectionRevision: 7)

        try MainMeterPublication.replace(reading, in: store)
        #expect(
            MainMeterPublication.load(from: store, defaults: defaults, shared: shared) == reading)

        shared.set("claude", forKey: AppGroupConfig.mainMeterProviderKey)
        #expect(MainMeterPublication.load(from: store, defaults: defaults, shared: shared) == nil)
        shared.set("codex", forKey: AppGroupConfig.mainMeterProviderKey)
        shared.set("other", forKey: AppGroupConfig.codexMainMeterAccountKey)
        #expect(MainMeterPublication.load(from: store, defaults: defaults, shared: shared) == nil)
        shared.set("codex-work", forKey: AppGroupConfig.codexMainMeterAccountKey)
        shared.set(8, forKey: AppGroupConfig.mainMeterRevisionKey)
        #expect(MainMeterPublication.load(from: store, defaults: defaults, shared: shared) == nil)

        try MainMeterPublication.replace(nil, in: store)
        #expect(try store.readMainMeter() == nil)
        #expect(MainMeterPublication.load(from: store, defaults: defaults, shared: shared) == nil)
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
            ("main-meter.json", { _ = try store.readMainMeter() }),
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
            ("main-meter.json", { _ = try store.readMainMeter() }),
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

    @Test("migrateSnapshotIfNeeded copies legacy snapshot when destination is empty")
    func migratesLegacySnapshot() throws {
        let legacyDir =
            root
            .appending(path: "claudemeter-legacy-\(UUID().uuidString)")
        let sharedDir =
            root
            .appending(path: "claudemeter-shared-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: legacyDir)
            try? FileManager.default.removeItem(at: sharedDir)
        }
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        let legacy = SnapshotStore(directory: legacyDir)
        let shared = SnapshotStore(directory: sharedDir)
        let snap = makeSnapshot()

        try legacy.writeLatest(snap)
        try SnapshotStore.migrateSnapshotIfNeeded(from: legacy, to: shared)

        let recovered = try #require(try shared.readLatest())
        #expect(
            recovered.limits.currentSession.percentUsed == snap.limits.currentSession.percentUsed)
    }

    @Test("migrateSnapshotIfNeeded does not overwrite existing shared snapshot")
    func skipsMigrationWhenDestinationExists() throws {
        let legacyDir =
            root
            .appending(path: "claudemeter-legacy-\(UUID().uuidString)")
        let sharedDir =
            root
            .appending(path: "claudemeter-shared-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: legacyDir)
            try? FileManager.default.removeItem(at: sharedDir)
        }
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        let legacy = SnapshotStore(directory: legacyDir)
        let shared = SnapshotStore(directory: sharedDir)

        var legacySnap = makeSnapshot()
        legacySnap.limits.currentSession = LimitWindow(
            percentUsed: 10, resetsAt: nil, rawResetText: nil)
        var sharedSnap = makeSnapshot()
        sharedSnap.limits.currentSession = LimitWindow(
            percentUsed: 99, resetsAt: nil, rawResetText: nil)

        try legacy.writeLatest(legacySnap)
        try shared.writeLatest(sharedSnap)
        try SnapshotStore.migrateSnapshotIfNeeded(from: legacy, to: shared)

        let recovered = try #require(try shared.readLatest())
        #expect(recovered.limits.currentSession.percentUsed == 99)
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
