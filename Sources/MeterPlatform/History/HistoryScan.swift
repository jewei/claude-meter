import Foundation
import MeterDomain

/// The files that one scan can count, and the accounts that it could not read completely.
public struct HistoryScan<Parser: HistoryFileParser>: Sendable {
    /// One history file and the records parsed from it.
    public struct File: Sendable {
        public let path: String
        /// The account of the root that found the file.
        public let account: AccountID
        public let parser: Parser
        /// False when part of the file was not parsed: an incomplete final line, a skipped long
        /// line, the per-file record limit, or bytes left for a later scan.
        public let isComplete: Bool
    }

    /// What one scan did. Tests use it to check the limits and the incremental reads.
    public struct Work: Equatable, Sendable {
        public var bytesRead = 0
        public var parsedLines = 0
        public var cacheHits = 0
        public var directoryEntries = 0
        public var discoveredFiles = 0
        public var cachedFiles = 0
        public var cachedRecords = 0
    }

    /// Every account of the scanned roots, in root order.
    public let accounts: [AccountID]
    /// Files in root order, then in path order. A file with two paths, such as a hard link in
    /// two roots, appears once, for the root that comes first.
    public let files: [File]
    /// Accounts whose folders were not completely discovered or read in this scan.
    public let partialAccounts: Set<AccountID>
    public let work: Work

    /// `accounts` in root order; an account that several roots share comes once.
    init(
        accounts: [AccountID], files: [File], partialAccounts: Set<AccountID>, work: Work
    ) {
        var unique: [AccountID] = []
        for account in accounts where !unique.contains(account) { unique.append(account) }
        self.accounts = unique
        self.files = files
        self.partialAccounts = partialAccounts
        self.work = work
    }

    /// The files of one account, in root order and then in path order.
    public func files(of account: AccountID) -> [File] {
        files.filter { $0.account == account }
    }

    /// The history of every scanned account.
    ///
    /// `tally` is the empty tally for this read. `count` adds the records of one account's
    /// files to that account's copy of the tally; it can also mark the copy partial. An account
    /// is partial when its folders were not completely read, or a file has lines that could
    /// not be counted.
    public func tokenHistory(
        provider: ProviderID, tally: TokenDayTally,
        count: ([File], inout TokenDayTally) -> Void
    ) -> ProviderTokenHistory {
        var histories: [AccountID: TokenHistory] = [:]
        for account in accounts {
            let files = files(of: account)
            var accountTally = tally
            accountTally.isPartial =
                partialAccounts.contains(account)
                || files.contains { !$0.isComplete || $0.parser.isPartial }
            accountTally.hasRecords = files.contains { $0.parser.recordCount > 0 }
            count(files, &accountTally)
            histories[account] = accountTally.history
        }
        return ProviderTokenHistory(
            provider: provider, source: .thisMac, accounts: histories,
            coverageStart: tally.start, observedAt: tally.now,
            timeZoneID: tally.calendar.timeZone.identifier)
    }
}
