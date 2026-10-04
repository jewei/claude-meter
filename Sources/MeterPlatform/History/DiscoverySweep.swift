import Foundation

/// One discovery pass over every root. A sweep can take several scans. It keeps the files
/// that it found so far, capped to the newest files.
struct DiscoverySweep: Sendable {
    /// What one call of ``advance(maxEntries:maxFiles:since:match:cancellation:)`` found.
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
    mutating func advance(
        maxEntries: Int, maxFiles: Int, since start: Date, match: HistoryFileMatch,
        cancellation: BlockingIO.Cancellation
    ) -> Page {
        var page = Page()
        while page.entries < maxEntries, page.files.count < maxFiles, !cancellation.isCancelled {
            guard let entry = cursor.next(listing: DirectoryListing.entries(of:)) else { break }
            page.entries += 1
            guard entry.kind == .regularFile, match.matches(entry.name),
                let modified = DirectoryListing.modificationDate(ofRegularFile: entry.path),
                modified >= start
            else { continue }
            let found = DiscoveredFile(modified: modified, root: entry.root)
            page.files[entry.path] = page.files[entry.path]?.merged(with: found) ?? found
        }
        return page
    }

    /// Adds the files of one page, keeping the newest `limit` files.
    mutating func record(_ page: [String: DiscoveredFile], limit: Int) {
        if DiscoveredFile.merge(page, into: &files, limit: limit) { exceededFileLimit = true }
    }
}
