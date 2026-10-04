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
        /// The caller gave up. The listing can continue later from the same position.
        case cancelled
    }

    /// Where the next chunk of a directory listing starts.
    struct Position: Hashable, Sendable {
        /// Entries read so far, hidden entries included.
        var offset: Int
        /// The directory when its listing started, or nil in tests that list no real folder.
        var stamp: Stamp?
    }

    /// Identifies a directory and its contents. Adding, removing, or renaming an entry changes
    /// the modification time of the directory.
    struct Stamp: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
        let seconds: Int
        let nanoseconds: Int
    }

    /// Part of a directory listing.
    struct Chunk: Sendable {
        /// The visible entries of this part, sorted by name.
        var entries: [Entry]
        /// Where the next part starts, or nil at the end of the directory.
        var next: Position?
    }

    /// Lists one chunk of the directory at a path, from a position (nil for the start).
    typealias Function =
        @Sendable (String, Position?, BlockingIO.Cancellation) throws(ListingError) -> Chunk

    /// The listing that discovery uses: chunks of ``HistoryLimits/entriesPerListing`` entries.
    static let standard = chunks(of: HistoryLimits.entriesPerListing)

    /// A listing that reads at most `maxEntries` entries in one call.
    static func chunks(of maxEntries: Int) -> Function {
        { path, position, cancellation throws(ListingError) in
            try chunk(of: path, from: position, maxEntries: maxEntries, cancellation: cancellation)
        }
    }

    /// Reads at most `maxEntries` entries of the directory at `path`, from `position`. A
    /// symbolic link at `path` is not followed.
    ///
    /// The position counts entries in the order of the file system. When the directory changed
    /// since the listing started, an offset can point anywhere, so the listing starts again;
    /// entries that come twice are merged by path. The read stops with
    /// ``ListingError/cancelled`` as soon as `cancellation` is set.
    static func chunk(
        of path: String, from position: Position?, maxEntries: Int,
        cancellation: BlockingIO.Cancellation
    ) throws(ListingError) -> Chunk {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ENOENT ? .missing : .unreadable(errno: errno)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw .unreadable(errno: code)
        }
        guard let directory = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw .unreadable(errno: code)
        }
        defer { closedir(directory) }

        let stamp = Stamp(
            device: info.st_dev, inode: info.st_ino, seconds: info.st_mtimespec.tv_sec,
            nanoseconds: info.st_mtimespec.tv_nsec)
        var offset = 0
        if let position, position.stamp == stamp {
            while offset < position.offset {
                guard !cancellation.isCancelled else { throw .cancelled }
                guard try next(in: directory) != nil else { return Chunk(entries: [], next: nil) }
                offset += 1
            }
        }

        var entries: [Entry] = []
        let end = offset + max(1, maxEntries)
        while offset < end {
            guard !cancellation.isCancelled else { throw .cancelled }
            guard let entry = try next(in: directory) else {
                return Chunk(entries: entries.sorted { $0.name < $1.name }, next: nil)
            }
            offset += 1
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
        return Chunk(
            entries: entries.sorted { $0.name < $1.name },
            next: Position(offset: offset, stamp: stamp))
    }

    /// The next raw entry, or nil at the end of the directory.
    private static func next(
        in directory: UnsafeMutablePointer<DIR>
    ) throws(ListingError) -> UnsafeMutablePointer<dirent>? {
        errno = 0
        guard let entry = readdir(directory) else {
            if errno != 0 { throw .unreadable(errno: errno) }
            return nil
        }
        return entry
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
