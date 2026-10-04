import Foundation

/// Walks the directory trees of several roots and can stop and resume after any entry.
///
/// The cursor takes one entry from each unfinished root in turn, so a large root cannot
/// starve the others. It does no I/O itself: ``next(listing:)`` asks for each directory
/// listing, which keeps the walk a pure value that tests can drive.
struct DiscoveryCursor: Sendable {
    typealias Listing = (String) throws(DirectoryListing.ListingError) -> [DirectoryListing.Entry]

    /// One visited entry and the index of the root that found it.
    struct Entry: Hashable, Sendable {
        let path: String
        let name: String
        let kind: DirectoryListing.Entry.Kind
        let root: Int
    }

    /// The walk of one root: a depth-first stack of directories to list, and the listing that
    /// is in progress.
    private struct Walk: Sendable {
        var directories: [String]
        var directory = ""
        var listing: [DirectoryListing.Entry] = []
        var position = 0
        var isFinished = false
    }

    let roots: [String]
    private var walks: [Walk]
    private var nextRoot = 0
    /// Roots where a directory could not be listed in this sweep. Their files can be missing.
    private(set) var failedRoots: Set<Int> = []

    init(roots: [String]) {
        self.roots = roots
        walks = roots.map { Walk(directories: [$0]) }
    }

    /// True when every root was walked to the end.
    var isComplete: Bool { walks.allSatisfy(\.isFinished) }

    func isFinished(root: Int) -> Bool { walks[root].isFinished }

    /// The next entry, or nil when every root is finished. A directory entry is returned
    /// before the walk descends into it.
    mutating func next(listing: Listing) -> Entry? {
        while !isComplete {
            let root = nextRoot
            nextRoot = (root + 1) % walks.count
            guard !walks[root].isFinished else { continue }
            if let entry = nextEntry(of: root, listing: listing) { return entry }
        }
        return nil
    }

    private mutating func nextEntry(of root: Int, listing: Listing) -> Entry? {
        while true {
            let walk = walks[root]
            if walk.position < walk.listing.count {
                let entry = walk.listing[walk.position]
                walks[root].position += 1
                return Entry(
                    path: DirectoryListing.child(named: entry.name, in: walk.directory),
                    name: entry.name, kind: entry.kind, root: root)
            }
            guard let directory = walks[root].directories.popLast() else {
                walks[root].isFinished = true
                walks[root].listing = []
                return nil
            }
            list(directory, of: root, listing: listing)
        }
    }

    private mutating func list(_ directory: String, of root: Int, listing: Listing) {
        walks[root].directory = directory
        walks[root].position = 0
        do {
            let entries = try listing(directory)
            walks[root].listing = entries
            // Push subdirectories in reverse, so the walk descends in name order.
            let children = entries.filter { $0.kind == .directory }.reversed().map {
                DirectoryListing.child(named: $0.name, in: directory)
            }
            walks[root].directories += children
        } catch {
            walks[root].listing = []
            // A missing root has no records. A directory deleted during the walk had files
            // that no longer exist. Neither hides anything.
            if case .unreadable = error { failedRoots.insert(root) }
        }
    }
}
