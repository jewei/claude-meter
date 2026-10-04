import Darwin
import Foundation

/// Blocking file-system reads for discovery. Call them inside ``BlockingIO``.
enum DirectoryListing {
    /// One named entry of a directory. Hidden entries, whose names start with a dot, are
    /// never listed.
    struct Entry: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case directory
            case regularFile
            /// A symbolic link or a special file. Discovery never follows or reads it.
            case other
        }

        let name: String
        let kind: Kind
    }

    enum ListingError: Error, Equatable {
        /// The directory does not exist (any more).
        case missing
        case unreadable(errno: Int32)
    }

    /// The visible entries of the directory at `path`, sorted by name. A symbolic link at
    /// `path` is not followed.
    static func entries(of path: String) throws(ListingError) -> [Entry] {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ENOENT ? .missing : .unreadable(errno: errno)
        }
        guard let directory = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw .unreadable(errno: code)
        }
        defer { closedir(directory) }

        var entries: [Entry] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw .unreadable(errno: errno) }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard !name.hasPrefix(".") else { continue }
            let kind: Entry.Kind =
                switch Int32(entry.pointee.d_type) {
                case DT_DIR: .directory
                case DT_REG: .regularFile
                case DT_UNKNOWN: Self.kind(of: child(named: name, in: path))
                default: .other
                }
            entries.append(Entry(name: name, kind: kind))
        }
        return entries.sorted { $0.name < $1.name }
    }

    /// The modification date of a regular file at `path`, or nil when the path is missing, a
    /// symbolic link, or a special file.
    static func modificationDate(ofRegularFile path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let time = info.st_mtimespec
        return Date(
            timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }

    /// The path of the entry `name` in the directory at `path`.
    static func child(named name: String, in path: String) -> String {
        path.hasSuffix("/") ? path + name : path + "/" + name
    }

    private static func kind(of path: String) -> Entry.Kind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .other }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .regularFile
        default: return .other
        }
    }
}
