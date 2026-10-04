import Foundation
import MeterDomain
import MeterPlatform

/// Counts Claude Code tokens on this Mac from the session logs in each account's config dir.
///
/// Each account counts only `projects/**/*.jsonl` under its own config dir. A response
/// counts input, output, cache-read, and cache-write tokens once, even when it was streamed
/// over several lines or copied to another session file. The scan state lives in memory for
/// the life of this value.
public final class ClaudeTokenHistory: TokenHistoryProvider {
    private let roots: @Sendable () async throws -> [HistoryRoot]
    private let calendar: Calendar
    private let scanner = HistoryScanner<ClaudeHistoryParser>(match: .fileExtension("jsonl"))

    /// - Parameters:
    ///   - roots: Each account's config dir, such as `~/.claude`, read at every refresh. When
    ///     the config dirs cannot be listed, throw (see ``ClaudeProvider/accounts(for:)``): the
    ///     read fails and keeps its last value, and the scan state stays. An empty list would
    ///     discard the scan state, and the next read would read every file again.
    ///   - calendar: Assigns records to local days. The default follows the system time zone.
    public init(
        roots: @escaping @Sendable () async throws -> [HistoryRoot],
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.roots = roots
        self.calendar = calendar
    }

    /// Always ``ProviderID/claude``.
    public var id: ProviderID { .claude }

    /// Token history for today and the previous six local days, labeled as this Mac.
    public func history(now: Date, previous _: ProviderTokenHistory?) async throws
        -> ProviderTokenHistory
    {
        let tally = try TokenDayTally(now: now, calendar: calendar)
        let scanRoots = try await roots().map { root in
            HistoryRoot(
                account: root.account,
                directory: root.directory.appending(path: "projects", directoryHint: .isDirectory))
        }
        let scan = try await scanner.scan(scanRoots, since: tally.start)
        return scan.tokenHistory(provider: .claude, tally: tally) { files, tally in
            var records = TokenRecordSet()
            for file in files { records.formUnion(file.parser.records) }
            for record in records.records { tally.add(record) }
        }
    }
}
