import Foundation
import Testing

@testable import ClaudeMeterProviders

struct TranscriptIdentityTests {
    @Test("Atomic replacement invalidates cost and activity caches", arguments: [false, true])
    func atomicReplacement(reloadCostCache: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = project.appendingPathComponent("session.jsonl")
        let disk = root.appendingPathComponent("cache.json")
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        func line(_ id: String) -> String {
            "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"requestId\":\"r\",\"message\":{\"id\":\"\(id)\",\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":100}}}\n"
        }
        let mtime = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        try Data((line("a") + line("a")).utf8).write(to: file)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        let before = try #require(try JournalReader.regularTranscriptMetadata(at: file, fm: fm))
        let costCache = CostUsageCache(persistenceURL: disk)
        let activity = ActivityScanner(projectsPaths: [root], cache: ActivityCache())
        #expect(
            CostUsageScanner(projectsPath: root, cache: costCache).scan(now: now).models.first?
                .inputTokens == 100)
        #expect(activity.scan(now: now).total == 1)

        try Data((line("a") + line("b")).utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        let after = try #require(try JournalReader.regularTranscriptMetadata(at: file, fm: fm))
        #expect(before.identity != after.identity)
        #expect(before.fileSize == after.fileSize)
        #expect(before.modificationDate == after.modificationDate)
        let cache = reloadCostCache ? CostUsageCache(persistenceURL: disk) : costCache
        #expect(
            CostUsageScanner(projectsPath: root, cache: cache).scan(now: now).models.first?
                .inputTokens == 200)
        #expect(activity.scan(now: now).total == 2)
    }

    @Test("A changed descriptor stamp makes a transcript read uncacheable")
    func descriptorChangedDuringRead() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("first\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let before = try #require(
            try JournalReader.regularTranscriptMetadata(at: file, fm: .default))
        let read = try #require(
            JournalReader.readRegularTranscript(
                at: file, maxFullReadBytes: 1_024, tailReadBytes: 512,
                afterRead: {
                    let handle = try! FileHandle(forWritingTo: file)
                    try! handle.seekToEnd()
                    try! handle.write(contentsOf: Data("second\n".utf8))
                    try! handle.close()
                }))
        #expect(read.metadata == before)
        #expect(!read.isCacheable)
        #expect(read.isPartial)
        let stable = try #require(
            JournalReader.readRegularTranscript(
                at: file, maxFullReadBytes: 1_024, tailReadBytes: 512))
        #expect(stable.isCacheable)
        #expect(stable.metadata != before)
    }

    @Test("Version five cost caches are rebuilt")
    func legacyCacheIsRejected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let entry: [String: Any] = [
            "path": file.path, "modDate": 0, "fileSize": 0,
            "timeZoneIdentifier": "UTC", "isPartial": false, "records": [],
        ]
        try JSONSerialization.data(withJSONObject: ["version": 5, "entries": [entry]]).write(
            to: file)
        #expect(CostUsageCache(persistenceURL: file).entryCount == 0)
    }
}
