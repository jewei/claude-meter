import Foundation

/// Walks the directory trees of several roots and can stop and resume after any entry.
///
/// The cursor takes one entry from each unfinished root in turn, so a large root cannot
/// starve the others. It reads each directory in chunks and keeps the position, so a large
/// folder takes several calls instead of one long one. It does no I/O itself:
/// ``next(listing:)`` asks for each chunk, which keeps the walk a pure value that tests can
/// drive.
struct DiscoveryCursor: Sendable {
    typealias Listing = (Location, DirectoryListing.Position?) throws(DirectoryListing.ListingError)
        -> DirectoryListing.Chunk

    /// One visited entry, the directory that holds it, and the index of the root that found it.
    struct Entry: Hashable, Sendable {
        let path: String
        let name: String
        let kind: DirectoryListing.Entry.Kind
        let location: Location

        var root: Int { location.root }
    }

    /// A directory in the walk of one root.
    struct Location: Hashable, Sendable {
        let directory: String
        let root: Int
    }

    /// The walk of one root: a depth-first stack of directories to list, and the directory that
    /// is in progress.
    private struct Walk: Sendable {
        var directories: [String]
        var directory: String?
        /// Where the next chunk of `directory` starts. Nil before its first chunk.
        var position: DirectoryListing.Position?
        var hasMore = false
        /// Subdirectories of `directory` found so far. The walk descends into them, in name
        /// order, after the last chunk.
        var children: Set<String> = []
        var chunk: [DirectoryListing.Entry] = []
        var index = 0
        var isFinished = false
    }

    private enum Step {
        case entry(Entry)
        case finished
        /// The listing was cancelled. The walk resumes at the same chunk.
        case interrupted
    }

    private var walks: [Walk]
    private var nextRoot = 0
    /// Roots where a directory could not be listed in this sweep. Their files can be missing.
    private(set) var failedRoots: Set<Int> = []
    /// Directories that this sweep skips because their listing took too long.
    private var skipped: Set<Location> = []

    init(roots: [String]) {
        walks = roots.map { Walk(directories: [$0]) }
    }

    /// True when every root was walked to the end.
    var isComplete: Bool { walks.allSatisfy(\.isFinished) }

    func isFinished(root: Int) -> Bool { walks[root].isFinished }

    /// The next entry, or nil when every root is finished or the listing was cancelled. A
    /// directory entry is returned before the walk descends into it.
    mutating func next(listing: Listing) -> Entry? {
        while !isComplete {
            let root = nextRoot
            nextRoot = (root + 1) % walks.count
            guard !walks[root].isFinished else { continue }
            switch nextEntry(of: root, listing: listing) {
            case .entry(let entry): return entry
            case .finished: continue
            case .interrupted:
                // The same root goes first when the walk resumes, so the order stays the same.
                nextRoot = root
                return nil
            }
        }
        return nil
    }

    /// Skips the rest of a directory whose listing took too long, and marks its root failed.
    /// The walk goes on with the other directories, also when it has not reached `location`
    /// yet.
    mutating func skip(_ location: Location) {
        skipped.insert(location)
        failedRoots.insert(location.root)
    }

    private mutating func nextEntry(of root: Int, listing: Listing) -> Step {
        while true {
            guard let directory = walks[root].directory else {
                guard let directory = walks[root].directories.popLast() else {
                    walks[root].isFinished = true
                    return .finished
                }
                walks[root].directory = directory
                walks[root].position = nil
                walks[root].hasMore = true
                continue
            }
            let location = Location(directory: directory, root: root)
            if skipped.contains(location) {
                finishDirectory(of: root)
                continue
            }
            let walk = walks[root]
            if walk.index < walk.chunk.count {
                let entry = walk.chunk[walk.index]
                walks[root].index += 1
                return .entry(
                    Entry(
                        path: DirectoryListing.child(named: entry.name, in: directory),
                        name: entry.name, kind: entry.kind, location: location))
            }
            guard walk.hasMore else {
                finishDirectory(of: root)
                continue
            }
            guard read(location, listing: listing) else { return .interrupted }
        }
    }

    /// Reads the next chunk of the directory in progress. Returns false when the listing was
    /// cancelled; the walk then reads the same chunk again later.
    private mutating func read(_ location: Location, listing: Listing) -> Bool {
        let root = location.root
        do {
            let chunk = try listing(location, walks[root].position)
            walks[root].chunk = chunk.entries
            walks[root].position = chunk.next
            walks[root].hasMore = chunk.next != nil
            for entry in chunk.entries where entry.kind == .directory {
                walks[root].children.insert(
                    DirectoryListing.child(named: entry.name, in: location.directory))
            }
        } catch .cancelled {
            return false
        } catch {
            walks[root].chunk = []
            walks[root].hasMore = false
            // A missing root has no records. A directory deleted during the walk had files
            // that no longer exist. Neither hides anything.
            if case .unreadable = error { failedRoots.insert(root) }
        }
        walks[root].index = 0
        return true
    }

    private mutating func finishDirectory(of root: Int) {
        // Pushed in reverse, so the walk descends in name order.
        walks[root].directories += walks[root].children.sorted(by: >)
        walks[root].directory = nil
        walks[root].position = nil
        walks[root].hasMore = false
        walks[root].children = []
        walks[root].chunk = []
        walks[root].index = 0
    }
}
