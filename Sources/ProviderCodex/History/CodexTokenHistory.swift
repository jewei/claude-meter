import Foundation
import MeterDomain
import MeterPlatform

/// Counts Codex tokens on this Mac from the rollout files in each account's Codex home.
///
/// Each account counts only `sessions` and `archived_sessions` under its own home.
/// Cumulative counters are reconciled, copies of a session count once, and a fork counts
/// only the history that it owns. Each event counts input plus output tokens. The scan state
/// lives in memory for the life of this value.
public final class CodexTokenHistory: TokenHistoryProvider {
    private static let folders = ["sessions", "archived_sessions"]

    private let roots: @Sendable () async -> [HistoryRoot]
    private let calendar: Calendar
    private let scanner = HistoryScanner<CodexSessionLog>(match: .fileExtension("jsonl"))

    /// - Parameters:
    ///   - roots: Each account's Codex home, such as `~/.codex`, read at every refresh.
    ///   - calendar: Assigns records to local days. The default follows the system time zone.
    public init(
        roots: @escaping @Sendable () async -> [HistoryRoot],
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.roots = roots
        self.calendar = calendar
    }

    public var id: ProviderID { .codex }

    /// Token history for today and the previous six local days, labeled as this Mac.
    public func history(now: Date) async throws -> ProviderTokenHistory {
        let tally = try TokenDayTally(now: now, calendar: calendar)
        let scanRoots = await roots().flatMap { root in
            Self.folders.map { folder in
                HistoryRoot(
                    account: root.account,
                    directory: root.directory.appending(path: folder, directoryHint: .isDirectory))
            }
        }
        let scan = try await scanner.scan(scanRoots, since: tally.start)
        return scan.tokenHistory(provider: .codex, tally: tally) { files, tally in
            var sessions = CodexSessionSet()
            for file in files { sessions.insert(file.parser, path: file.path) }
            let owned = sessions.ownedRecords()
            if owned.isPartial { tally.isPartial = true }
            for record in owned.records { tally.add(record) }
        }
    }
}
