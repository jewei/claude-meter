import Foundation

/// One discovery pass over every root. A sweep can take several scans. It keeps the files
/// that it found so far, capped to the newest files.
struct DiscoverySweep: Sendable {
    /// What one call of ``advance(maxEntries:maxFiles:since:match:listing:activity:cancellation:)``
    /// found.
    struct Page: Sendable {
        var entries = 0
        var files: [String: DiscoveredFile] = [:]
    }

    private(set) var cursor: DiscoveryCursor
    /// Files found by this sweep, at most the file limit.
    private(set) var files: [String: DiscoveredFile] = [:]
    /// The sweep found more files than the limit allows, so some files are not counted.
    private(set) var exceededFileLimit = false

    init(roots: [String]) {
        cursor = DiscoveryCursor(roots: roots)
    }

    var isComplete: Bool { cursor.isComplete }

    /// Visits at most `maxEntries` directory entries and stops after `maxFiles` matching files.
    ///
    /// A match is a regular file, not a symbolic link, modified at or after `start`. Other
    /// entries are skipped without making history partial: a link or a special file is not a
    /// record file of this folder. This call blocks; run it inside ``BlockingIO``.
    ///
    /// `activity` holds the directory of the blocking call in progress, so a caller that gave
    /// up can skip that directory with ``skip(_:)``.
    mutating func advance(
        maxEntries: Int, maxFiles: Int, since start: Date, match: HistoryFileMatch,
        listing: DirectoryListing.Function, activity: Locked<DiscoveryCursor.Location?>,
        cancellation: BlockingIO.Cancellation
    ) -> Page {
        var page = Page()
        while page.entries < maxEntries, page.files.count < maxFiles, !cancellation.isCancelled {
            let next = cursor.next { location, position throws(DirectoryListing.ListingError) in
                activity.withLock { $0 = location }
                defer { activity.withLock { $0 = nil } }
                return try listing(location.directory, position, cancellation)
            }
            guard let entry = next else { break }
            page.entries += 1
            guard entry.kind == .regularFile, match.matches(entry.name) else { continue }
            activity.withLock { $0 = entry.location }
            let modified = DirectoryListing.modificationDate(ofRegularFile: entry.path)
            activity.withLock { $0 = nil }
            guard let modified, modified >= start else { continue }
            let found = DiscoveredFile(
                modified: modified, root: entry.root, folder: entry.location.directory)
            page.files[entry.path] = page.files[entry.path]?.merged(with: found) ?? found
        }
        return page
    }

    /// Skips the rest of a directory whose listing took too long. Its root reads as partial.
    mutating func skip(_ location: DiscoveryCursor.Location) {
        cursor.skip(location)
    }

    /// Adds the files of one page, keeping the newest `limit` files.
    mutating func record(_ page: [String: DiscoveredFile], limit: Int) {
        if DiscoveredFile.merge(page, into: &files, limit: limit) { exceededFileLimit = true }
    }
}
