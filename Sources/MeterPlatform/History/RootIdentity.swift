import Darwin
import Foundation
import MeterDomain

/// A scan root as it is on disk now.
///
/// A change of any field resets discovery and the parse cache: a folder that was replaced at
/// the same path holds other files, and a changed account owns other records.
struct RootIdentity: Hashable, Sendable {
    let account: AccountID
    /// The canonical path, with symbolic links resolved when the folder exists.
    let path: String
    let exists: Bool
    let device: Int32
    let inode: UInt64

    /// The roots in order, without a later root at a path that an earlier root has. The
    /// earlier root keeps its account. This call blocks; run it inside ``BlockingIO``.
    static func resolve(_ roots: [HistoryRoot]) -> [RootIdentity] {
        var seen = Set<String>()
        return roots.compactMap { root in
            let identity = RootIdentity(root)
            return seen.insert(identity.path).inserted ? identity : nil
        }
    }

    private init(_ root: HistoryRoot) {
        account = root.account
        let standardized = root.directory.standardizedFileURL.path
        if let resolved = realpath(standardized, nil) {
            path = String(cString: resolved)
            free(resolved)
        } else {
            path = standardized
        }
        var info = stat()
        exists = lstat(path, &info) == 0
        device = exists ? info.st_dev : 0
        inode = exists ? info.st_ino : 0
    }
}
