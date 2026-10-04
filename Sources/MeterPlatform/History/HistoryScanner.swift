import Foundation
import MeterDomain

/// Reads append-only JSONL history files incrementally, in memory only, within
/// ``HistoryLimits``.
///
/// One scanner serves one provider for the life of the app. Between scans it keeps a
/// discovery cursor, the inventory of found files, and one cursor per file, so an unchanged
/// file costs one `open` and `fstat`, and a grown file costs only its new lines. A scan checks
/// for cancellation between directory pages and between files, and keeps the progress that it
/// made before the cancellation.
///
/// Blocking reads run in the ``BlockingIO/history`` pool, so stuck history folders never make
/// quota reads fail. A blocking read that times out ends that phase of the scan, and the
/// result is partial: a stuck root check returns the files of the last scan with every
/// account partial, a stuck directory page ends discovery, and a stuck file ends reading. A
/// root check, discovery, or file whose earlier read is still stuck is skipped until that read
/// ends, so repeated scans do not abandon one more thread each.
public actor HistoryScanner<Parser: HistoryFileParser> {
    private typealias Cursor = FileCursor<Parser>

    private let match: HistoryFileMatch
    private let limits: HistoryLimits
    private let pool: BlockingIO
    private let queue = ScanQueue()
    /// Pool keys of this scanner's root checks and discovery pages. File reads use the path.
    private let rootsKey: String
    private let discoveryKey: String

    /// The roots as configured for the saved state.
    private var configured: [HistoryRoot] = []
    private var roots: [RootIdentity] = []
    private var start: Date?
    /// The sweep in progress. Nil after a sweep completes, so the next scan starts a new one.
    private var sweep: DiscoverySweep?
    /// Found files: the last complete sweep plus the files of the current sweep so far.
    private var inventory: [String: DiscoveredFile] = [:]
    /// The inventory dropped files at the file limit since the last complete sweep.
    private var inventoryOverflowed = false
    /// Roots that the last complete sweep could not list completely. Nil before the first
    /// complete sweep, when no inventory covers any root yet.
    private var lastSweepFailedRoots: Set<Int>?
    private var cursors: [String: Cursor] = [:]

    public init(match: HistoryFileMatch, limits: HistoryLimits = HistoryLimits()) {
        self.init(match: match, limits: limits, pool: .history)
    }

    /// Tests pass their own pool, so stuck test reads never reach the shared pools.
    init(match: HistoryFileMatch, limits: HistoryLimits, pool: BlockingIO) {
        self.match = match
        self.limits = limits
        self.pool = pool
        let id = UUID().uuidString
        rootsKey = "history-scanner/\(id)/roots"
        discoveryKey = "history-scanner/\(id)/discovery"
    }

    /// Scans `roots` for files modified at or after `start`.
    ///
    /// A change of the roots, of a root folder on disk, or of `start` discards all saved
    /// state first. Scans run one at a time.
    public func scan(_ roots: [HistoryRoot], since start: Date) async throws -> HistoryScan<Parser>
    {
        try await queue.enter()
        do {
            let result = try await scanInTurn(roots, since: start)
            await queue.leave()
            return result
        } catch {
            await queue.leave()
            throw error
        }
    }

    private func scanInTurn(
        _ configured: [HistoryRoot], since start: Date
    ) async throws -> HistoryScan<Parser> {
        guard let identities = try await resolve(configured) else {
            return unresolved(configured, since: start)
        }
        if identities != roots || start != self.start {
            roots = identities
            self.start = start
            sweep = nil
            inventory = [:]
            inventoryOverflowed = false
            lastSweepFailedRoots = nil
            cursors = [:]
        }
        self.configured = configured
        var work = HistoryScan<Parser>.Work()
        let discovery = try await discover(since: start, work: &work)
        let unreadRoots = try await readFiles(work: &work)

        var partialRoots = unreadRoots.union(undiscoveredRoots(discovery))
        if discovery.exceededFileLimit || inventoryOverflowed {
            partialRoots.formUnion(roots.indices)
        }
        work.cachedFiles = cursors.count
        work.cachedRecords = cursors.values.reduce(0) { $0 + $1.parser.recordCount }
        var accounts: [AccountID] = []
        for root in roots where !accounts.contains(root.account) { accounts.append(root.account) }
        return HistoryScan(
            accounts: accounts, files: countedFiles(),
            partialAccounts: Set(partialRoots.map { roots[$0].account }), work: work)
    }

    /// The roots as they are on disk now, or nil when the check timed out, found the pool
    /// full, or an earlier check is still stuck.
    private func resolve(_ configured: [HistoryRoot]) async throws -> [RootIdentity]? {
        guard !pool.isStuck(rootsKey) else { return nil }
        do {
            return try await blocking(key: rootsKey) { _ in RootIdentity.resolve(configured) }
        } catch is TimeoutError, is BlockingIO.BusyError {
            return nil
        }
    }

    /// The result of a scan whose roots could not be checked: the files of the last scan when
    /// it had the same roots and start, and every account partial.
    private func unresolved(_ configured: [HistoryRoot], since start: Date) -> HistoryScan<Parser> {
        var accounts: [AccountID] = []
        for root in configured where !accounts.contains(root.account) {
            accounts.append(root.account)
        }
        let isSaved = configured == self.configured && start == self.start
        return HistoryScan(
            accounts: accounts, files: isSaved ? countedFiles() : [],
            partialAccounts: Set(accounts), work: HistoryScan<Parser>.Work())
    }

    /// Roots whose files the inventory can miss: a folder could not be listed, or the root
    /// was not walked to its end by the current sweep or by a complete earlier sweep.
    private func undiscoveredRoots(_ current: DiscoverySweep) -> Set<Int> {
        var partial = current.cursor.failedRoots
        for index in roots.indices where !current.cursor.isFinished(root: index) {
            if let failed = lastSweepFailedRoots, !failed.contains(index) { continue }
            partial.insert(index)
        }
        return partial
    }

    /// Advances discovery within this scan's entry and file budgets, one blocking call per
    /// page. Returns the sweep as it was at the end, for the partial rules.
    private func discover(
        since start: Date, work: inout HistoryScan<Parser>.Work
    ) async throws -> DiscoverySweep {
        var current = sweep ?? DiscoverySweep(roots: roots.map(\.path))
        sweep = current
        while !current.isComplete, work.directoryEntries < limits.directoryEntries,
            work.discoveredFiles < limits.files
        {
            try Task.checkCancellation()
            // An earlier page is still stuck. The sweep stays incomplete until it ends.
            if pool.isStuck(discoveryKey) { break }
            let maxEntries = min(
                HistoryLimits.entriesPerCall, limits.directoryEntries - work.directoryEntries)
            let maxFiles = limits.files - work.discoveredFiles
            let (match, before) = (self.match, current)
            let result: (DiscoverySweep, DiscoverySweep.Page)
            do {
                result = try await blocking(key: discoveryKey) { cancellation in
                    var next = before
                    let page = next.advance(
                        maxEntries: maxEntries, maxFiles: maxFiles, since: start, match: match,
                        cancellation: cancellation)
                    return (next, page)
                }
            } catch is TimeoutError, is BlockingIO.BusyError {
                // A stuck folder must not hide the files found so far. The sweep stays
                // incomplete, so its roots read as partial, and the next scan tries again.
                break
            }
            let (after, page) = result
            current = after
            current.record(page.files, limit: limits.files)
            // An incomplete page is no evidence that an earlier file was deleted, so pages
            // only add to the inventory until the sweep completes.
            if DiscoveredFile.merge(page.files, into: &inventory, limit: limits.files) {
                inventoryOverflowed = true
            }
            sweep = current
            work.directoryEntries += page.entries
            work.discoveredFiles += page.files.count
        }
        if current.isComplete {
            inventory = current.files
            inventoryOverflowed = false
            lastSweepFailedRoots = current.cursor.failedRoots
            sweep = nil
        }
        cursors = cursors.filter { inventory[$0.key] != nil }
        return current
    }

    /// Reads the inventory, newest files first, so recent files get the byte budget first.
    /// Returns the roots of files that this scan could not count completely.
    private func readFiles(work: inout HistoryScan<Parser>.Work) async throws -> Set<Int> {
        var unreadRoots = Set<Int>()
        var records = 0
        var isReadingStopped = false
        for (path, file) in DiscoveredFile.newestFirst(inventory) {
            try Task.checkCancellation()
            if records > limits.records {
                // The record limit keeps the newest files. Older files are not read at all.
                cursors[path] = nil
                unreadRoots.insert(file.root)
                continue
            }
            if isReadingStopped {
                unreadRoots.insert(file.root)
            } else {
                switch try await read(path, work: &work) {
                case .read: break
                case .notRead: unreadRoots.insert(file.root)
                case .stopReading:
                    unreadRoots.insert(file.root)
                    isReadingStopped = true
                }
            }
            guard let cursor = cursors[path] else {
                unreadRoots.insert(file.root)
                continue
            }
            records += cursor.parser.recordCount
            if records > limits.records {
                cursors[path] = nil
                unreadRoots.insert(file.root)
            }
        }
        return unreadRoots
    }

    private enum ReadResult {
        /// The cursor is current. It can still be incomplete, which the file reports.
        case read
        /// The file keeps its previous cursor, or none.
        case notRead
        /// A blocking read timed out or found no free thread.
        case stopReading
    }

    /// Reads one file and stores its cursor.
    private func read(
        _ path: String, work: inout HistoryScan<Parser>.Work
    ) async throws -> ReadResult {
        // An earlier read of this file is still stuck. Skip only this file.
        if pool.isStuck(path) { return .notRead }
        let (previous, limits) = (cursors[path], self.limits)
        let available = limits.scanBytes - work.bytesRead
        let progress: Cursor.Progress
        do {
            progress = try await blocking(key: path) { cancellation in
                try Cursor.read(
                    path, after: previous, available: available, limits: limits,
                    cancellation: cancellation)
            }
        } catch is TimeoutError, is BlockingIO.BusyError {
            // A stuck disk would hold one more thread per file. Stop reading for this scan.
            return .stopReading
        }
        work.bytesRead += progress.bytesRead
        work.parsedLines += progress.parsedLines
        switch progress.outcome {
        case .unchanged:
            work.cacheHits += 1
            return .read
        case .read(let cursor):
            cursors[path] = cursor
            return .read
        case .failed(.budget), .failed(.changed):
            // Keep the previous cursor: its records are still valid, and it resumes later.
            return .notRead
        case .failed:
            cursors[path] = nil
            return .notRead
        }
    }

    /// Runs blocking work with the scan time limit. A full pool is tried again after a short
    /// wait; cancellation ends the wait.
    private func blocking<Value: Sendable>(
        key: String, _ work: @escaping @Sendable (BlockingIO.Cancellation) throws -> Value
    ) async throws -> Value {
        var attempts = 0
        while true {
            do {
                return try await pool.run(timeout: limits.blockingTimeout, key: key, work)
            } catch is BlockingIO.BusyError where attempts < HistoryLimits.busyRetries {
                attempts += 1
                try await Task.sleep(for: HistoryLimits.busyRetryDelay)
            }
        }
    }

    /// Cached files in root order, then path order, with each hard-linked file once.
    private func countedFiles() -> [HistoryScan<Parser>.File] {
        let ordered = inventory.compactMap { path, file -> (String, Int, Cursor)? in
            cursors[path].map { (path, file.root, $0) }
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var seen = Set<FileStamp.FileID>()
        return ordered.compactMap { path, root, cursor in
            guard seen.insert(cursor.stamp.fileID).inserted else { return nil }
            return HistoryScan.File(
                path: path, account: roots[root].account, parser: cursor.parser,
                isComplete: cursor.isComplete)
        }
    }
}
