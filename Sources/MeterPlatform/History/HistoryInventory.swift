import Foundation

/// The history files that discovery found, kept between scans.
///
/// A sweep can take several scans. Until it completes, its pages only add files, so the files
/// of the last complete sweep keep their folders complete. A completed sweep replaces the
/// files, so deleted files leave and files modified before the range start leave, except a
/// file that a folder change hid from the sweep and that a read found (see
/// ``complete(_:limit:wasRead:)``).
struct HistoryInventory: Sendable {
    /// The sweep in progress. Nil after a sweep completes, so the next scan starts a new one.
    var sweep: DiscoverySweep?
    /// Found files: the last complete sweep plus the files of the current sweep so far.
    private(set) var files: [String: DiscoveredFile] = [:]
    /// Files were dropped at the file limit by the last complete sweep or since it, so the
    /// inventory can miss files until a complete sweep finds them all within the limit.
    private(set) var overflowed = false
    /// Roots that the last complete sweep could not list completely. Nil before the first
    /// complete sweep, when no inventory covers any root yet.
    private var lastSweepFailedRoots: Set<Int>?

    /// Adds the files of one page of the sweep in progress, keeping the newest `limit` files.
    mutating func add(_ page: [String: DiscoveredFile], limit: Int) {
        // An incomplete page is no evidence that an earlier file was deleted, so pages only
        // add to the inventory until the sweep completes.
        if DiscoveredFile.merge(page, into: &files, limit: limit) { overflowed = true }
    }

    /// Replaces the files with those of a complete sweep.
    ///
    /// A folder that changed while the sweep listed it can have moved a file before the
    /// listing position, so the sweep did not see it. Such a file stays from the earlier
    /// inventory when `wasRead` says that a read found it. A file that a read found missing
    /// leaves.
    mutating func complete(
        _ sweep: DiscoverySweep, limit: Int, wasRead: (String) -> Bool
    ) {
        var found = sweep.files
        let changed = sweep.cursor.changedFolders
        let moved = files.filter { path, file in
            found[path] == nil && changed.contains(file.folder) && wasRead(path)
        }
        // The merge runs first, so the moved files stay even when the sweep itself overflowed.
        let movedOverflowed = DiscoveredFile.merge(moved, into: &found, limit: limit)
        // The files that this sweep dropped stay missing until a later sweep completes within
        // the limit, so the early pages of that sweep still read as partial.
        overflowed = sweep.exceededFileLimit || movedOverflowed
        files = found
        lastSweepFailedRoots = sweep.cursor.failedRoots
        self.sweep = nil
    }

    /// Roots whose files the inventory can miss: a folder could not be listed, or the root
    /// was not walked to its end by the current sweep or by a complete earlier sweep.
    func undiscoveredRoots(_ current: DiscoverySweep, roots: Range<Int>) -> Set<Int> {
        var partial = current.cursor.failedRoots
        for index in roots where !current.cursor.isFinished(root: index) {
            if let failed = lastSweepFailedRoots, !failed.contains(index) { continue }
            partial.insert(index)
        }
        return partial
    }
}
