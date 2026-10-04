import Darwin
import Foundation

/// The identity, size, and change times of an open file. Two equal stamps mean that the file
/// did not change between the two checks.
struct FileStamp: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    /// The stamp of the regular file open at `descriptor`.
    init(descriptor: Int32) throws(FileReadError) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw .notRegularFile }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    /// The file itself: two paths with the same ID are hard links to one file.
    struct FileID: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    var fileID: FileID { FileID(device: device, inode: inode) }

    /// True when both stamps belong to the same file, even if its contents changed.
    func isSameFile(as other: FileStamp) -> Bool {
        fileID == other.fileID
    }
}
