import Foundation
import MeterDomain

/// Reads append-only JSONL history files incrementally, in memory only, within
/// ``HistoryLimits``.
///
/// One scanner serves one provider for the life of the app. Between scans it keeps a
/// discovery cursor, the inventory of found files, and one cursor per file, so an unchanged
/// file costs one `open` and `fstat`, and a grown file costs only its new lines. A scan checks
/// for cancellation between directory pages, inside a folder listing, and between files, and
/// keeps the progress that it made before the cancellation.
///
/// Blocking reads run in the ``BlockingIO/history`` pool, so stuck history folders never make
/// quota reads fail. A blocking read that times out ends that phase of the scan, and the
/// result is partial: a stuck root check returns the files of the last scan with every
/// account partial, a stuck directory page ends discovery and makes the sweep skip the folder
/// that it waited for, and a stuck file ends reading. A root check, discovery, or file whose
/// earlier read is still stuck is skipped until that read ends, so repeated scans do not
/// abandon one more thread each.
public actor HistoryScanner<Parser: HistoryFileParser> {
    private typealias Cursor = FileCursor<Parser>

    private let match: HistoryFileMatch
    private let limits: HistoryLimits
    private let pool: BlockingIO
    private let listing: DirectoryListing.Function
    private let busyWait: BlockingIO.BusyWait
    private let queue = ScanQueue()
    /// Pool keys of this scanner's root checks and discovery pages. File reads use the path.
    private let rootsKey: String
    private let discoveryKey: String

    /// The roots as configured for the saved state.
    private var configured: [HistoryRoot] = []
    private var roots: [RootIdentity] = []
    private var start: Date?
    private var inventory = HistoryInventory()
    private var cursors: [String: Cursor] = [:]

    public init(match: HistoryFileMatch, limits: HistoryLimits = HistoryLimits()) {
        self.init(match: match, limits: limits, pool: .history)
    }

    /// Tests pass their own pool, so stuck test reads never reach the shared pools, and can
    /// pass a listing that blocks and a shorter wait for a full pool.
    init(
        match: HistoryFileMatch, limits: HistoryLimits, pool: BlockingIO,
        listing: @escaping DirectoryListing.Function = DirectoryListing.standard,
        busyWait: BlockingIO.BusyWait = HistoryLimits.busyWait
    ) {
        self.match = match
        self.limits = limits
        self.pool = pool
        self.listing = listing
        self.busyWait = busyWait
        let id = UUID().uuidString
        rootsKey = "history-scanner/\(id)/roots"
        discoveryKey = "history-scanner/\(id)/discovery"
    }

    /// Scans `roots` for files modified at or after `start`.
    ///
    /// A change of the roots or of a root folder on disk, or an earlier `start`, discards all
    /// saved state first. A later `start`, as at each local midnight, keeps the saved state,
    /// files modified before it included: a saved date can be older than the file, which a
    /// resumed session can have changed since. Their records before `start` do not count, and
    /// the next complete sweep leaves them out, except a file in a folder that changed during
    /// the sweep and that a read found. Scans run one at a time.
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
        if identities != roots || !(self.start.map { start >= $0 } ?? false) {
            // An earlier start needs files that discovery skipped as too old.
            roots = identities
            inventory = HistoryInventory()
            cursors = [:]
        }
        // A later start only narrows the range, so every file keeps its cursor.
        self.start = start
        self.configured = configured
        var work = HistoryScan<Parser>.Work()
        let discovery = try await discover(since: start, work: &work)
        let unreadRoots = try await readFiles(work: &work)

        var partialRoots = unreadRoots.union(
            inventory.undiscoveredRoots(discovery, roots: roots.indices))
        if discovery.exceededFileLimit || inventory.overflowed {
            partialRoots.formUnion(roots.indices)
        }
        work.cachedFiles = cursors.count
        work.cachedRecords = cursors.values.reduce(0) { $0 + $1.parser.recordCount }
        return HistoryScan(
            accounts: roots.map(\.account), files: countedFiles(),
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
    /// it had the same roots and the same or an earlier start, and every account partial.
    private func unresolved(_ configured: [HistoryRoot], since start: Date) -> HistoryScan<Parser> {
        let isSaved = configured == self.configured && (self.start.map { start >= $0 } ?? false)
        return HistoryScan(
            accounts: configured.map(\.account), files: isSaved ? countedFiles() : [],
            partialAccounts: Set(configured.map(\.account)), work: HistoryScan<Parser>.Work())
    }

    /// Advances discovery within this scan's entry and file budgets, one blocking call per
    /// page. Returns the sweep as it was at the end, for the partial rules.
    private func discover(
        since start: Date, work: inout HistoryScan<Parser>.Work
    ) async throws -> DiscoverySweep {
        var current = inventory.sweep ?? DiscoverySweep(roots: roots.map(\.path))
        inventory.sweep = current
        while !current.isComplete, work.directoryEntries < limits.directoryEntries,
            work.discoveredFiles < limits.files
        {
            try Task.checkCancellation()
            // An earlier page is still stuck. The sweep stays incomplete until it ends.
            if pool.isStuck(discoveryKey) { break }
            let maxEntries = min(
                HistoryLimits.entriesPerCall, limits.directoryEntries - work.directoryEntries)
            let maxFiles = limits.files - work.discoveredFiles
            let (match, listing, before) = (self.match, self.listing, current)
            let activity = Locked<DiscoveryCursor.Location?>(nil)
            let result: (DiscoverySweep, DiscoverySweep.Page)
            do {
                result = try await blocking(key: discoveryKey) { cancellation in
                    var next = before
                    let page = next.advance(
                        maxEntries: maxEntries, maxFiles: maxFiles, since: start, match: match,
                        listing: listing, activity: activity, cancellation: cancellation)
                    return (next, page)
                }
            } catch is TimeoutError {
                // The page is lost, but the files of earlier pages still count. The sweep skips
                // the folder that the page waited for and marks its root failed, so the next
                // page goes on past it instead of waiting for the same folder again.
                if let stuck = activity.value {
                    current.skip(stuck)
                    inventory.sweep = current
                }
                break
            } catch is BlockingIO.BusyError {
                break
            }
            let (after, page) = result
            current = after
            current.record(page.files, limit: limits.files)
            inventory.add(page.files, limit: limits.files)
            inventory.sweep = current
            work.directoryEntries += page.entries
            work.discoveredFiles += page.files.count
        }
        if current.isComplete {
            let cursors = self.cursors
            inventory.complete(current, limit: limits.files) { cursors[$0] != nil }
        }
        cursors = cursors.filter { inventory.files[$0.key] != nil }
        return current
    }

    /// Reads the inventory, newest files first, so recent files get the byte budget first.
    /// Returns the roots of files that this scan could not count completely.
    private func readFiles(work: inout HistoryScan<Parser>.Work) async throws -> Set<Int> {
        var unreadRoots = Set<Int>()
        var records = 0
        var isReadingStopped = false
        for (path, file) in DiscoveredFile.newestFirst(inventory.files) {
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
        try await pool.run(
            timeout: limits.blockingTimeout, key: key, busyWait: busyWait, work)
    }

    /// Cached files in root order, then path order, with each hard-linked file once.
    private func countedFiles() -> [HistoryScan<Parser>.File] {
        let ordered = inventory.files.compactMap { path, file -> (String, Int, Cursor)? in
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
