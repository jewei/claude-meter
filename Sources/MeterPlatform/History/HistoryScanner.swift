import Foundation
import MeterDomain

/// Reads append-only JSONL history files incrementally, in memory only, within
/// ``HistoryLimits``.
///
/// One scanner serves one provider for the life of the app. Between scans it keeps a
/// discovery cursor, the inventory of found files, and one cursor per file, so an unchanged
/// file costs one `open` and `fstat`, and a grown file costs only its new lines. Blocking
/// reads run inside ``BlockingIO``. A scan checks for cancellation between directory pages and
/// between files, and keeps the progress that it made before the cancellation. A blocking
/// read that times out ends that phase of the scan, and the result is partial.
public actor HistoryScanner<Parser: HistoryFileParser> {
    private typealias Cursor = FileCursor<Parser>

    private let match: HistoryFileMatch
    private let limits: HistoryLimits
    private let queue = ScanQueue()

    private var roots: [RootIdentity] = []
    private var start: Date?
    /// The sweep in progress. Nil after a sweep completes, so the next scan starts a new one.
    private var sweep: DiscoverySweep?
    /// Found files: the last complete sweep plus the files of the current sweep so far.
    private var inventory: [String: DiscoveredFile] = [:]
    /// The inventory dropped files at the file limit since the last complete sweep.
    private var inventoryOverflowed = false
    private var cursors: [String: Cursor] = [:]

    public init(match: HistoryFileMatch, limits: HistoryLimits = HistoryLimits()) {
        self.match = match
        self.limits = limits
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
        let identities = try await blocking { _ in RootIdentity.resolve(configured) }
        if identities != roots || start != self.start {
            roots = identities
            self.start = start
            sweep = nil
            inventory = [:]
            inventoryOverflowed = false
            cursors = [:]
        }
        var work = HistoryScan<Parser>.Work()
        let discovery = try await discover(since: start, work: &work)
        let unreadRoots = try await readFiles(work: &work)

        var partialRoots = unreadRoots.union(discovery.cursor.failedRoots)
        for index in roots.indices where !discovery.cursor.isFinished(root: index) {
            partialRoots.insert(index)
        }
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
            let maxEntries = min(
                HistoryLimits.entriesPerCall, limits.directoryEntries - work.directoryEntries)
            let maxFiles = limits.files - work.discoveredFiles
            let (match, before) = (self.match, current)
            let result: (DiscoverySweep, DiscoverySweep.Page)
            do {
                result = try await blocking { cancellation in
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
        let (previous, limits) = (cursors[path], self.limits)
        let available = limits.scanBytes - work.bytesRead
        let progress: Cursor.Progress
        do {
            progress = try await blocking { cancellation in
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
        _ work: @escaping @Sendable (BlockingIO.Cancellation) throws -> Value
    ) async throws -> Value {
        var attempts = 0
        while true {
            do {
                return try await BlockingIO.run(timeout: HistoryLimits.blockingTimeout, work)
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
