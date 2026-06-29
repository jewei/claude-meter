import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("SessionEventStore")
struct SessionEventStoreTests {
    private let now = Date(timeIntervalSince1970: 1_782_269_456)

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes a marker `<account>/<name>.json` with the given mtime.
    private func writeMarker(
        _ json: [String: Any], account: String, name: String, mtime: Date, in root: URL
    ) throws {
        let dir = root.appendingPathComponent(account, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    @Test func parsesFreshStopAndNotificationAcrossAccounts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "s1", "cwd": "/Users/x/dev/claude-meter"],
            account: "claude", name: "s1.Stop", mtime: now, in: root)
        try writeMarker(
            [
                "hook_event_name": "Notification", "session_id": "s2",
                "cwd": "/Users/x/dev/other", "message": "Claude needs your permission",
            ],
            account: "claude-work", name: "s2.Notification", mtime: now, in: root)

        let events = SessionEventStore.drain(eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120)
            .sorted { ($0.sessionId ?? "") < ($1.sessionId ?? "") }
        #expect(events.count == 2)

        let stop = events[0]
        #expect(stop.kind == .stop)
        #expect(stop.accountKey == "claude")
        #expect(stop.projectName == "claude-meter")

        let note = events[1]
        #expect(note.kind == .notification)
        #expect(note.accountKey == "claude-work")
        #expect(note.message == "Claude needs your permission")
        #expect(note.projectName == "other")
    }

    @Test func drainConsumesMarkers() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "s1"],
            account: "claude", name: "s1.Stop", mtime: now, in: root)

        #expect(SessionEventStore.drain(eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120).count == 1)
        // Second drain finds nothing — the marker was consumed.
        #expect(SessionEventStore.drain(eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120).isEmpty)
    }

    @Test func staleMarkersAreDroppedButStillDeleted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "old"],
            account: "claude", name: "old.Stop", mtime: now.addingTimeInterval(-600), in: root)

        // Older than maxAge → not emitted (no burst of old pings on launch)...
        #expect(SessionEventStore.drain(eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120).isEmpty)
        // ...but cleaned up so it can't accumulate.
        let dir = root.appendingPathComponent("claude")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining.isEmpty)
    }

    @Test func skipsDisabledAccounts() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "a"],
            account: "claude", name: "a.Stop", mtime: now, in: root)
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "b"],
            account: "claude-work", name: "b.Stop", mtime: now, in: root)

        let events = SessionEventStore.drain(
            eventsRoot: root, disabledAccountKeys: ["claude-work"], now: now, maxAge: 120)
        #expect(events.count == 1)
        #expect(events.first?.accountKey == "claude")
        // The disabled account's marker is consumed (so it can't pile up) but never
        // surfaced as an event.
        let disabledDir = root.appendingPathComponent("claude-work")
        #expect(try FileManager.default.contentsOfDirectory(atPath: disabledDir.path).isEmpty)
    }

    @Test func freshButUnparseableMarkerIsLeftForRetry() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("partial.Stop.json")
        try "{ not valid json".data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)

        // Fresh but unparseable (e.g. a mid-write read) → not emitted, NOT deleted.
        #expect(
            SessionEventStore.drain(
                eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120
            ).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Once it ages past maxAge it gets cleaned up.
        _ = SessionEventStore.drain(
            eventsRoot: root, disabledAccountKeys: [], now: now.addingTimeInterval(600), maxAge: 120)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
