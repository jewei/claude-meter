import Foundation

/// A history file that discovery found, and the root that found it.
struct DiscoveredFile: Hashable, Sendable {
    let modified: Date
    /// The index of the configured root that found the file. Discovery records it because an
    /// enumerated path can differ from the configured root path, so a path prefix cannot
    /// identify the owner.
    let root: Int

    /// Two sightings of one path: the newer date, and the root that comes first in the
    /// configuration, so nested roots give the file to the earlier root.
    func merged(with newer: DiscoveredFile) -> DiscoveredFile {
        DiscoveredFile(modified: newer.modified, root: min(root, newer.root))
    }

    /// Adds `page` to `files` and keeps the newest `limit` files. Returns true when files were
    /// dropped because of the limit.
    static func merge(
        _ page: [String: DiscoveredFile], into files: inout [String: DiscoveredFile], limit: Int
    ) -> Bool {
        files.merge(page) { old, new in old.merged(with: new) }
        guard files.count > limit else { return false }
        files = Dictionary(uniqueKeysWithValues: newestFirst(files).prefix(max(0, limit)))
        return true
    }

    /// Paths with the most recently modified files first. Equal dates sort by path, so the
    /// order never depends on the host.
    static func newestFirst(_ files: [String: DiscoveredFile]) -> [(String, DiscoveredFile)] {
        files.sorted { left, right in
            left.value.modified == right.value.modified
                ? left.key < right.key : left.value.modified > right.value.modified
        }.map { ($0.key, $0.value) }
    }
}
