import Testing
import Foundation
@testable import ClaudeMeterCore

private let fixedDate = Date(timeIntervalSince1970: 1_782_108_000) // 2026-06-22T06:00:00Z
private let klTZ = TimeZone(identifier: "Asia/Kuala_Lumpur")!

private func makeStore() throws -> SnapshotStore {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "ClaudeMeterTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return SnapshotStore(directory: dir)
}

private func makeSnapshot(sessionPercent: Double = 25, weekPercent: Double = 30) -> ClaudeUsageSnapshot {
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
struct SnapshotStoreTests {

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

    @Test("readLatest returns nil when no file exists")
    func readMissingReturnsNil() throws {
        let store = try makeStore()
        #expect(try store.readLatest() == nil)
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

    // MARK: - Raw output

    @Test("Writes and verifies raw output file exists")
    func writesRawOutput() throws {
        let store = try makeStore()
        let text = "Current session\n25% used\nResets 2:50pm (Asia/Kuala_Lumpur)\n"

        try store.writeRawOutput(text)

        let rawURL = store.directory.appending(path: "current.raw.txt")
        #expect(FileManager.default.fileExists(atPath: rawURL.path))
        let readBack = try String(contentsOf: rawURL, encoding: .utf8)
        #expect(readBack == text)
    }

    // MARK: - Directory

    @Test("applicationSupport() creates ClaudeMeter directory")
    func appSupportDir() throws {
        let store = try SnapshotStore.applicationSupport()
        #expect(store.directory.lastPathComponent == "ClaudeMeter")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.directory.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    // MARK: - Dates survive encode/decode

    @Test("Reset dates survive JSON roundtrip")
    func datesRoundtrip() throws {
        let store = try makeStore()
        let snap = makeSnapshot()
        let originalResetsAt = snap.limits.currentSession.resetsAt!

        try store.writeLatest(snap)
        let recovered = try #require(try store.readLatest())

        let delta = abs(recovered.limits.currentSession.resetsAt!.timeIntervalSince(originalResetsAt))
        #expect(delta < 1.0)
    }
}
