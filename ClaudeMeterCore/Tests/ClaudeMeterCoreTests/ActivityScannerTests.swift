import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("ActivityScanner")
struct ActivityScannerTests {
    private func makeScanner(lines: [String]) throws -> (ActivityScanner, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("project-a", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: file)
        return (ActivityScanner(projectsPaths: [root]), root)
    }

    private func line(id: String, ts: String) -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"\(id)","usage":{"input_tokens":1,"output_tokens":1}}}
        """
    }

    /// Builds a local-time timestamp string so weekday/hour bucketing is testable
    /// regardless of the machine's timezone.
    private func localTS(_ components: DateComponents) -> (String, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let date = cal.date(from: components)!
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (f.string(from: date), date)
    }

    @Test func bucketsByLocalWeekdayAndHour() throws {
        // 2026-06-29 is a Monday. 09:xx local.
        let (ts, date) = localTS(
            DateComponents(year: 2026, month: 6, day: 29, hour: 9, minute: 30))
        let (scanner, _) = try makeScanner(lines: [line(id: "a", ts: ts)])
        let map = scanner.scan(daysBack: 60, now: date)

        #expect(map.total == 1)
        #expect(map.counts[0][9] == 1)  // Monday (row 0), hour 9
        // Nothing else populated.
        let elsewhere = map.counts.enumerated().flatMap { day, hours in
            hours.enumerated().compactMap { hour, c in (day, hour) == (0, 9) ? nil : c }
        }
        #expect(elsewhere.allSatisfy { $0 == 0 })
    }

    @Test func dedupsStreamingChunksByMessageId() throws {
        let (ts, date) = localTS(
            DateComponents(year: 2026, month: 6, day: 29, hour: 14, minute: 0))
        // Same message id three times (streaming) → counts once.
        let (scanner, _) = try makeScanner(lines: [
            line(id: "m1", ts: ts), line(id: "m1", ts: ts), line(id: "m1", ts: ts),
        ])
        let map = scanner.scan(daysBack: 60, now: date)
        #expect(map.total == 1)
        #expect(map.counts[0][14] == 1)
    }

    @Test func dedupesRootsResolvingToSamePath() throws {
        let (ts, date) = localTS(
            DateComponents(year: 2026, month: 6, day: 29, hour: 11))
        let (_, root) = try makeScanner(lines: [line(id: "a", ts: ts)])
        // A symlink to the same root must not double-count its messages.
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

        let scanner = ActivityScanner(projectsPaths: [root, link, root])
        let map = scanner.scan(daysBack: 60, now: date)
        #expect(map.total == 1)
        #expect(map.counts[0][11] == 1)
    }

    @Test("Subagent transcripts under <session>/subagents/ are counted; fork files skipped")
    func countsSubagentTranscriptsSkipsForks() throws {
        let (ts, date) = localTS(
            DateComponents(year: 2026, month: 6, day: 29, hour: 9))
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("p", isDirectory: true)
        let subagents = project
            .appendingPathComponent("session-uuid", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try fm.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try line(id: "top", ts: ts).data(using: .utf8)!
            .write(to: project.appendingPathComponent("session-uuid.jsonl"))
        try line(id: "sub", ts: ts).data(using: .utf8)!
            .write(to: subagents.appendingPathComponent("agent-abc.jsonl"))
        try line(id: "fork", ts: ts).data(using: .utf8)!
            .write(to: subagents.appendingPathComponent("agent-acompact-x.jsonl"))

        let map = ActivityScanner(projectsPaths: [root]).scan(daysBack: 60, now: date)
        #expect(map.total == 2)  // top-level + subagent; acompact fork excluded
        #expect(map.counts[0][9] == 2)
    }

    @Test func excludesRecordsBeforeCutoff() throws {
        let (recentTS, now) = localTS(
            DateComponents(year: 2026, month: 6, day: 29, hour: 10))
        let (oldTS, _) = localTS(
            DateComponents(year: 2026, month: 1, day: 1, hour: 10))
        let (scanner, _) = try makeScanner(lines: [
            line(id: "old", ts: oldTS), line(id: "new", ts: recentTS),
        ])
        let map = scanner.scan(daysBack: 7, now: now)
        #expect(map.total == 1)  // only the recent one
    }
}
