import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

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

    @Test func recognizesSupportedTerminalPrograms() {
        #expect(TerminalRoute(termProgram: "Ghostty", tty: nil, identifier: nil)?.client == .ghostty)
        #expect(
            TerminalRoute(termProgram: "Apple_Terminal", tty: nil, identifier: nil)?.client
                == .terminal)
        #expect(TerminalRoute(termProgram: "iTerm.app", tty: nil, identifier: nil)?.client == .iTerm2)
        #expect(TerminalRoute(termProgram: "WezTerm", tty: nil, identifier: nil)?.client == .wezTerm)
        #expect(
            TerminalRoute(termProgram: "WarpTerminal", tty: nil, identifier: nil)?.client == .warp)
        #expect(TerminalRoute(termProgram: "unknown", tty: nil, identifier: nil) == nil)
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

    @Test func parsesTerminalRouteFromMarkerFilename() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let route = Data("WezTerm\nttys003\n42".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "s1"],
            account: "claude", name: "s1.Stop.123.cmr-\(route)", mtime: now, in: root)

        let event = try #require(
            SessionEventStore.drain(
                eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120
            ).first)
        #expect(event.terminalRoute?.client == .wezTerm)
        #expect(event.terminalRoute?.tty == "ttys003")
        #expect(event.terminalRoute?.deviceTTY == "/dev/ttys003")
        #expect(event.terminalRoute?.identifier == "42")
    }

    @Test func parsesStopFailureErrorTypeAndClassifiesLimitBlock() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMarker(
            ["hook_event_name": "StopFailure", "session_id": "s1", "error_type": "rate_limit"],
            account: "claude", name: "s1.StopFailure", mtime: now, in: root)
        try writeMarker(
            ["hook_event_name": "StopFailure", "session_id": "s2", "error_type": "server_error"],
            account: "claude", name: "s2.StopFailure", mtime: now, in: root)

        let events = SessionEventStore.drain(eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120)
            .sorted { ($0.sessionId ?? "") < ($1.sessionId ?? "") }
        #expect(events.count == 2)

        #expect(events[0].kind == .stopFailure)
        #expect(events[0].errorType == "rate_limit")
        #expect(events[0].isLimitBlock)  // rate_limit → real block

        #expect(events[1].errorType == "server_error")
        #expect(!events[1].isLimitBlock)  // server_error → noise, no alert
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

    @Test func consumesSubagentStopsWithoutEmittingThem() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "main"],
            account: "claude", name: "main.Stop", mtime: now, in: root)
        try writeMarker(
            [
                "hook_event_name": "Stop", "session_id": "main",
                "agent_id": "agent-worker-1",
            ],
            account: "claude", name: "subagent.Stop", mtime: now, in: root)
        try writeMarker(
            [
                "hook_event_name": "Notification", "session_id": "main",
                "agent_id": "agent-worker-1", "message": "Permission needed",
            ],
            account: "claude", name: "subagent.Notification", mtime: now, in: root)

        let events = SessionEventStore.drain(
            eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120)

        #expect(events.count == 2)
        #expect(events.contains { $0.kind == .stop && !$0.isSubagent })
        #expect(events.contains { $0.kind == .notification && $0.isSubagent })
        let dir = root.appendingPathComponent("claude")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
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
