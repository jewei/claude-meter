import Darwin
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
        #expect(
            TerminalRoute(termProgram: "Ghostty", tty: nil, identifier: nil)?.client == .ghostty)
        #expect(
            TerminalRoute(termProgram: "Apple_Terminal", tty: nil, identifier: nil)?.client
                == .terminal)
        #expect(
            TerminalRoute(termProgram: "iTerm.app", tty: nil, identifier: nil)?.client == .iTerm2)
        #expect(
            TerminalRoute(termProgram: "WezTerm", tty: nil, identifier: nil)?.client == .wezTerm)
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

        let events = SessionEventStore.drain(
            eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120
        )
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

        let events = SessionEventStore.drain(
            eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120
        )
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

        #expect(
            SessionEventStore.drain(
                eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120
            ).count == 1)
        // Second drain finds nothing — the marker was consumed.
        #expect(
            SessionEventStore.drain(
                eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120
            ).isEmpty)
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
        #expect(
            SessionEventStore.drain(
                eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120
            ).isEmpty)
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
            eventsRoot: root, disabledAccountKeys: [], now: now.addingTimeInterval(600), maxAge: 120
        )
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func implausiblyFutureMarkerIsConsumedWithoutEmission() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "future"],
            account: "claude", name: "future.Stop",
            mtime: now.addingTimeInterval(24 * 60 * 60), in: root)
        let events = SessionEventStore.drain(
            eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120)
        #expect(events.isEmpty)
        let dir = root.appendingPathComponent("claude")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func specialMarkerDoesNotBlock() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let marker = account.appendingPathComponent("special.Stop.json")
        #expect(marker.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)

        let clock = ContinuousClock()
        let start = clock.now
        #expect(
            SessionEventStore.parse(file: marker, accountKey: "claude", capturedAt: now) == nil)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func oversizedMarkerIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("oversized.Stop.json")
        try Data(repeating: 0x20, count: 256 * 1_024 + 1).write(to: marker)

        #expect(
            SessionEventStore.parse(file: marker, accountKey: "claude", capturedAt: now) == nil)
    }

    @Test func linkedAccountDirectoryIsIgnored() throws {
        let root = try makeRoot()
        let external = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "outside"],
            account: "target", name: "outside.Stop", mtime: now, in: external)
        let link = root.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: external.appendingPathComponent("target"))

        #expect(
            SessionEventStore.drain(
                eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120
            ).isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: external.appendingPathComponent("target/outside.Stop.json").path))
    }

    @Test func linkedEventsRootIsIgnored() throws {
        let base = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let targetRoot = base.appendingPathComponent("target-events", isDirectory: true)
        let linkedRoot = base.appendingPathComponent("events", isDirectory: true)
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "outside"],
            account: "claude", name: "outside.Stop", mtime: now, in: targetRoot)
        try FileManager.default.createSymbolicLink(
            at: linkedRoot, withDestinationURL: targetRoot)

        #expect(
            SessionEventStore.drain(
                eventsRoot: linkedRoot, disabledAccountKeys: [], now: now, maxAge: 120
            ).isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: targetRoot.appendingPathComponent("claude/outside.Stop.json").path))
    }

    @Test func staleSpecialAndOversizedMarkersAreSafelyRemoved() throws {
        let root = try makeRoot()
        let external = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let account = root.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)

        let fifo = account.appendingPathComponent("fifo.Stop.json")
        #expect(fifo.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)
        let oversized = account.appendingPathComponent("oversized.Stop.json")
        try Data(repeating: 0x20, count: 256 * 1_024 + 1).write(to: oversized)
        let target = external.appendingPathComponent("outside.json")
        try Data(#"{"hook_event_name":"Stop","session_id":"outside"}"#.utf8).write(to: target)
        let link = account.appendingPathComponent("linked.Stop.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let afterRetentionWindow = Date().addingTimeInterval(600)
        #expect(
            SessionEventStore.drain(
                eventsRoot: root, disabledAccountKeys: [], now: afterRetentionWindow, maxAge: 120
            ).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: account.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func replacementMarkerIsNotRemovedAfterOldMarkerIsRead() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "old"],
            account: "claude", name: "event.Stop", mtime: now, in: root)
        let marker = root.appendingPathComponent("claude/event.Stop.json")
        let replacement = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "session_id": "replacement",
        ])
        var didReplace = false

        let first = SessionEventStore.drain(
            eventsRoot: root,
            disabledAccountKeys: [],
            now: now,
            maxAge: 120,
            beforeConsume: { _, _ in
                guard !didReplace else { return }
                didReplace = true
                try? FileManager.default.removeItem(at: marker)
                try? replacement.write(to: marker)
                try? FileManager.default.setAttributes(
                    [.modificationDate: now], ofItemAtPath: marker.path)
            })

        #expect(didReplace)
        #expect(first.map(\.sessionId) == ["old"])
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let second = SessionEventStore.drain(
            eventsRoot: root, disabledAccountKeys: [], now: now, maxAge: 120)
        #expect(second.map(\.sessionId) == ["replacement"])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func accountDirectorySwapCannotDeleteOutsideEventsRoot() throws {
        let base = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("events", isDirectory: true)
        let externalRoot = base.appendingPathComponent("external", isDirectory: true)
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "old"],
            account: "claude", name: "old.Stop", mtime: now, in: root)
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "outside"],
            account: "target", name: "outside.Stop", mtime: now, in: externalRoot)

        let account = root.appendingPathComponent("claude", isDirectory: true)
        let displaced = base.appendingPathComponent("displaced", isDirectory: true)
        let externalAccount = externalRoot.appendingPathComponent("target", isDirectory: true)
        var didSwap = false
        let events = SessionEventStore.drain(
            eventsRoot: root,
            disabledAccountKeys: [],
            now: now,
            maxAge: 120,
            beforeConsume: { _, _ in
                guard !didSwap else { return }
                didSwap = true
                try? FileManager.default.moveItem(at: account, to: displaced)
                try? FileManager.default.createSymbolicLink(
                    at: account, withDestinationURL: externalAccount)
            })

        #expect(didSwap)
        #expect(events.map(\.sessionId) == ["old"])
        #expect(
            FileManager.default.fileExists(
                atPath: displaced.appendingPathComponent("old.Stop.json").path))
        #expect(
            FileManager.default.fileExists(
                atPath: externalAccount.appendingPathComponent("outside.Stop.json").path))
    }

    @Test func eventsRootSwapCannotDeleteOutsideOriginalRoot() throws {
        let base = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("events", isDirectory: true)
        let externalRoot = base.appendingPathComponent("external", isDirectory: true)
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "old"],
            account: "claude", name: "old.Stop", mtime: now, in: root)
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "outside"],
            account: "claude", name: "outside.Stop", mtime: now, in: externalRoot)

        let displacedRoot = base.appendingPathComponent("displaced-events", isDirectory: true)
        var didSwap = false
        let events = SessionEventStore.drain(
            eventsRoot: root,
            disabledAccountKeys: [],
            now: now,
            maxAge: 120,
            beforeConsume: { _, _ in
                guard !didSwap else { return }
                didSwap = true
                try? FileManager.default.moveItem(at: root, to: displacedRoot)
                try? FileManager.default.createSymbolicLink(
                    at: root, withDestinationURL: externalRoot)
            })

        #expect(didSwap)
        #expect(events.map(\.sessionId) == ["old"])
        #expect(
            FileManager.default.fileExists(
                atPath: displacedRoot.appendingPathComponent("claude/old.Stop.json").path))
        #expect(
            FileManager.default.fileExists(
                atPath: externalRoot.appendingPathComponent("claude/outside.Stop.json").path))
    }

    @Test func productionDrainRejectsLinkedDataRoot() throws {
        let fm = FileManager.default
        let base = try makeRoot()
        defer { try? fm.removeItem(at: base) }
        let external = base.appendingPathComponent("external", isDirectory: true)
        let linkedDataRoot = base.appendingPathComponent(".claude-meter", isDirectory: true)
        try writeMarker(
            ["hook_event_name": "Stop", "session_id": "outside"],
            account: "claude", name: "outside.Stop", mtime: now,
            in: external.appendingPathComponent("events"))
        let externalMarker = external.appendingPathComponent(
            "events/claude/outside.Stop.json")
        try fm.createSymbolicLink(at: linkedDataRoot, withDestinationURL: external)

        #expect(
            SessionEventStore.drain(
                dataRoot: linkedDataRoot,
                disabledAccountKeys: [],
                now: now,
                maxAge: 120
            ).isEmpty)
        #expect(fm.fileExists(atPath: externalMarker.path))
    }

    @Test func clearAllRemovesManagedFilesButKeepsDirectories() throws {
        let fm = FileManager.default
        let dataRoot = try makeRoot()
        defer { try? fm.removeItem(at: dataRoot) }
        let events = dataRoot.appendingPathComponent("events", isDirectory: true)
        let account = events.appendingPathComponent("claude", isDirectory: true)
        try fm.createDirectory(at: account, withIntermediateDirectories: true)
        let marker = account.appendingPathComponent("event.json")
        let direct = events.appendingPathComponent("direct.tmp")
        try Data("event".utf8).write(to: marker)
        try Data("direct".utf8).write(to: direct)

        SessionEventStore.clearAll(dataRoot: dataRoot)

        #expect(!fm.fileExists(atPath: marker.path))
        #expect(!fm.fileExists(atPath: direct.path))
        #expect(fm.fileExists(atPath: events.path))
        #expect(fm.fileExists(atPath: account.path))
    }

    @Test func clearAllRejectsLinkedDataRoot() throws {
        let fm = FileManager.default
        let base = try makeRoot()
        defer { try? fm.removeItem(at: base) }
        let external = base.appendingPathComponent("external", isDirectory: true)
        let account = external.appendingPathComponent("events/claude", isDirectory: true)
        let linkedDataRoot = base.appendingPathComponent(".claude-meter", isDirectory: true)
        try fm.createDirectory(at: account, withIntermediateDirectories: true)
        let marker = account.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: marker)
        try fm.createSymbolicLink(at: linkedDataRoot, withDestinationURL: external)

        SessionEventStore.clearAll(dataRoot: linkedDataRoot)

        #expect(fm.fileExists(atPath: marker.path))
        #expect(fm.fileExists(atPath: linkedDataRoot.path))
    }

    @Test func clearAllStopsWhenDataRootIsReplaced() throws {
        let fm = FileManager.default
        let base = try makeRoot()
        defer { try? fm.removeItem(at: base) }
        let dataRoot = base.appendingPathComponent(".claude-meter", isDirectory: true)
        let account = dataRoot.appendingPathComponent("events/claude", isDirectory: true)
        let external = base.appendingPathComponent("external", isDirectory: true)
        let externalAccount = external.appendingPathComponent("events/claude", isDirectory: true)
        try fm.createDirectory(at: account, withIntermediateDirectories: true)
        try fm.createDirectory(at: externalAccount, withIntermediateDirectories: true)
        let originalMarker = account.appendingPathComponent("old.json")
        let externalMarker = externalAccount.appendingPathComponent("outside.json")
        try Data("old".utf8).write(to: originalMarker)
        try Data("outside".utf8).write(to: externalMarker)
        let displaced = base.appendingPathComponent("displaced", isDirectory: true)
        var didSwap = false

        SessionEventStore.clearAll(
            dataRoot: dataRoot,
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
                atPath: displaced.appendingPathComponent("events/claude/old.json").path))
        #expect(fm.fileExists(atPath: externalMarker.path))
    }
}
