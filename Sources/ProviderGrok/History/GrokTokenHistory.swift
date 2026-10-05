import Foundation
import MeterDomain
import MeterPlatform

/// Counts Grok Build tokens on this Mac from the session updates in the Grok home.
///
/// The history reads completed turns in `sessions/**/updates.jsonl`. Event timestamps, not
/// file dates, set the day. Each turn counts input plus output tokens once per model. The
/// scan state lives in memory for the life of this value.
public final class GrokTokenHistory: TokenHistoryProvider {
    private let roots: @Sendable () async -> [HistoryRoot]
    private let calendar: Calendar
    private let scanner = HistoryScanner<GrokHistoryParser>(match: .fileName("updates.jsonl"))

    /// - Parameters:
    ///   - roots: The Grok home, such as `~/.grok` or `$GROK_HOME`, for the default account.
    ///   - calendar: Assigns records to local days. The default follows the system time zone.
    public init(
        roots: @escaping @Sendable () async -> [HistoryRoot],
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.roots = roots
        self.calendar = calendar
    }

    /// Always ``ProviderID/grok``.
    public var id: ProviderID { .grok }

    /// Token history for today and the previous six local days, labeled as this Mac.
    ///
    /// Throws `CancellationError`, or ``HistoryError`` for a clock outside the accepted dates.
    /// A blocking read that times out or finds no free thread does not throw: the scanner
    /// makes the history partial (`docs/token-history.md`).
    public func history(now: Date, previous _: ProviderTokenHistory?) async throws
        -> ProviderTokenHistory
    {
        let tally = try TokenDayTally(now: now, calendar: calendar)
        let scanRoots = await roots().map { root in
            HistoryRoot(
                account: root.account,
                directory: root.directory.appending(path: "sessions", directoryHint: .isDirectory))
        }
        let scan = try await scanner.scan(scanRoots, since: tally.start)
        return scan.tokenHistory(provider: .grok, tally: tally) { files, tally in
            var records = TokenRecordSet()
            for file in files { records.formUnion(file.parser.records) }
            for record in records.records { tally.add(record) }
        }
    }
}
