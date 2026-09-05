import Darwin
import Foundation

/// Reads local provider files without following a special file into a blocking
/// operation or allocating from an untrusted file size.
enum BoundedRegularFileReader {
    enum SymlinkPolicy {
        /// Follow a link, but accept its target only when it is a regular file.
        case allow
        /// Reject a link at the final path component.
        case reject
    }

    enum ReadError: Error, LocalizedError, Equatable {
        case invalidMaximumSize
        case invalidEntryName
        case openFailed(Int32)
        case inspectionFailed(Int32)
        case notRegularFile
        case notDirectory
        case tooLarge(maximumByteCount: Int)
        case readFailed(Int32)
        case fileChanged
        case directoryListingFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidMaximumSize:
                "The local file size limit is invalid."
            case .invalidEntryName:
                "The local file name is invalid."
            case .openFailed:
                "Could not open the local file."
            case .inspectionFailed:
                "Could not inspect the local file."
            case .notRegularFile:
                "The local file is not a regular file."
            case .notDirectory:
                "The local path is not a directory."
            case .tooLarge:
                "The local file is too large."
            case .readFailed:
                "Could not read the local file."
            case .fileChanged:
                "The local file changed while it was read."
            case .directoryListingFailed:
                "Could not list the local directory."
            }
        }
    }

    /// A directory opened without following its final path component. Child
    /// directories and files are resolved through this descriptor, so replacing a
    /// discovered path cannot redirect a later read or removal.
    final class AnchoredDirectory {
        struct Identity: Equatable {
            let device: dev_t
            let inode: ino_t

            init(_ status: stat) {
                self.device = status.st_dev
                self.inode = status.st_ino
            }
        }

        struct EntrySignature: Equatable {
            let identity: Identity
            let mode: mode_t
            let size: off_t
            let modificationSeconds: Int64
            let modificationNanoseconds: Int64
            let changeSeconds: Int64
            let changeNanoseconds: Int64

            init(_ status: stat) {
                self.identity = Identity(status)
                self.mode = status.st_mode
                self.size = status.st_size
                self.modificationSeconds = Int64(status.st_mtimespec.tv_sec)
                self.modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
                self.changeSeconds = Int64(status.st_ctimespec.tv_sec)
                self.changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            }
        }

        /// Metadata that describes bytes reached through one open descriptor.
        /// Link-count changes can update ctime when an atomic writer replaces the
        /// directory entry, but they do not change the bytes on the old descriptor.
        private struct ContentSignature: Equatable {
            let identity: Identity
            let size: off_t
            let modificationSeconds: Int64
            let modificationNanoseconds: Int64

            init(_ status: stat) {
                self.identity = Identity(status)
                self.size = status.st_size
                self.modificationSeconds = Int64(status.st_mtimespec.tv_sec)
                self.modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            }
        }

        struct Entry {
            let modificationDate: Date
            fileprivate let signature: EntrySignature

            fileprivate init(_ status: stat) {
                self.modificationDate = BoundedRegularFileReader.modificationDate(from: status)
                self.signature = EntrySignature(status)
            }
        }

        struct File {
            let data: Data
            let entry: Entry

            var modificationDate: Date { entry.modificationDate }
        }

        private let descriptor: Int32
        private let identity: Identity

        init(opening url: URL) throws {
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw ReadError.openFailed(errno) }

            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw ReadError.inspectionFailed(code)
            }
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                Darwin.close(descriptor)
                throw ReadError.notDirectory
            }
            self.descriptor = descriptor
            self.identity = Identity(status)
        }

        private init(descriptor: Int32, status: stat) {
            self.descriptor = descriptor
            self.identity = Identity(status)
        }

        deinit {
            Darwin.close(descriptor)
        }

        /// Opens one direct child directory. The entry name must be one path
        /// component, and a symbolic link is never followed.
        func directory(named name: String) throws -> AnchoredDirectory {
            try Self.validateEntryName(name)
            let childDescriptor = name.withCString {
                Darwin.openat(
                    descriptor, $0,
                    O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard childDescriptor >= 0 else { throw ReadError.openFailed(errno) }

            var status = stat()
            guard Darwin.fstat(childDescriptor, &status) == 0 else {
                let code = errno
                Darwin.close(childDescriptor)
                throw ReadError.inspectionFailed(code)
            }
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                Darwin.close(childDescriptor)
                throw ReadError.notDirectory
            }
            return AnchoredDirectory(descriptor: childDescriptor, status: status)
        }

        /// Lists direct entry names through a new descriptor for this same
        /// directory. A new descriptor keeps repeated listings independent.
        func entryNames() throws -> [String] {
            let enumerationDescriptor = ".".withCString {
                Darwin.openat(
                    descriptor, $0,
                    O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard enumerationDescriptor >= 0 else { throw ReadError.openFailed(errno) }
            guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
                let code = errno
                Darwin.close(enumerationDescriptor)
                throw ReadError.directoryListingFailed(code)
            }
            defer { Darwin.closedir(stream) }

            var names: [String] = []
            while true {
                errno = 0
                guard let entry = Darwin.readdir(stream) else {
                    if errno != 0 { throw ReadError.directoryListingFailed(errno) }
                    break
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(
                        to: CChar.self,
                        capacity: Int(entry.pointee.d_namlen) + 1
                    ) { String(validatingCString: $0) }
                }
                guard let name, name != ".", name != ".." else { continue }
                names.append(name)
            }
            return names.sorted()
        }

        /// Inspects one direct child without following it. This supplies stable
        /// metadata for stale-entry cleanup even when the child is a link, FIFO, or
        /// an oversized regular file that must not be read.
        func entry(named name: String) throws -> Entry {
            try Self.validateEntryName(name)
            var status = stat()
            let result = name.withCString {
                Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else { throw ReadError.inspectionFailed(errno) }
            return Entry(status)
        }

        /// Reads one direct child through `openat`. The returned identity belongs
        /// to the descriptor that supplied the data.
        func readFile(
            named name: String,
            maximumByteCount: Int,
            symlinkPolicy: SymlinkPolicy = .reject,
            afterRead: (() -> Void)? = nil
        ) throws -> File {
            try Self.validateEntryName(name)
            guard maximumByteCount >= 0 else { throw ReadError.invalidMaximumSize }

            var flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC
            if symlinkPolicy == .reject { flags |= O_NOFOLLOW }
            let fileDescriptor = name.withCString { Darwin.openat(descriptor, $0, flags) }
            guard fileDescriptor >= 0 else { throw ReadError.openFailed(errno) }
            defer { Darwin.close(fileDescriptor) }

            let statusBefore = try BoundedRegularFileReader.regularFileStatus(
                descriptor: fileDescriptor, maximumByteCount: maximumByteCount)
            let data = try BoundedRegularFileReader.readData(
                descriptor: fileDescriptor, expectedByteCount: Int(statusBefore.st_size))
            guard data.count == Int(statusBefore.st_size) else { throw ReadError.fileChanged }
            afterRead?()
            var statusAfter = stat()
            guard Darwin.fstat(fileDescriptor, &statusAfter) == 0 else {
                throw ReadError.inspectionFailed(errno)
            }
            guard ContentSignature(statusAfter) == ContentSignature(statusBefore) else {
                throw ReadError.fileChanged
            }
            return File(data: data, entry: Entry(statusAfter))
        }

        /// Returns true only when this descriptor still names the directory at
        /// `url`. Call this before a destructive operation that must stay below a
        /// specific root path.
        func stillNamesDirectory(at url: URL) -> Bool {
            guard let current = try? AnchoredDirectory(opening: url) else { return false }
            return current.identity == identity
        }

        /// Returns true only when `child` is still the direct, non-link directory
        /// at `name` in this directory.
        func stillContainsDirectory(_ child: AnchoredDirectory, named name: String) -> Bool {
            guard (try? Self.validateEntryName(name)) != nil else { return false }
            var status = stat()
            let result = name.withCString {
                Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            return result == 0
                && (status.st_mode & S_IFMT) == S_IFDIR
                && Identity(status) == child.identity
        }

        /// Removes one direct child only when the current directory entry has the
        /// same identity and metadata as the entry that was inspected.
        @discardableResult
        func unlinkEntry(named name: String, ifUnchangedSince entry: Entry) -> Bool {
            guard (try? Self.validateEntryName(name)) != nil else { return false }
            var status = stat()
            let inspectionResult = name.withCString {
                Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard inspectionResult == 0, EntrySignature(status) == entry.signature else {
                return false
            }
            return name.withCString { Darwin.unlinkat(descriptor, $0, 0) } == 0
        }

        /// Removes the regular file only when it is unchanged since `readFile`.
        @discardableResult
        func unlinkFile(named name: String, ifUnchangedSince file: File) -> Bool {
            unlinkEntry(named: name, ifUnchangedSince: file.entry)
        }

        private static func validateEntryName(_ name: String) throws {
            guard !name.isEmpty,
                name != ".",
                name != "..",
                !name.contains("/"),
                !name.utf8.contains(0)
            else { throw ReadError.invalidEntryName }
        }
    }

    static func read(
        at url: URL,
        maximumByteCount: Int,
        symlinkPolicy: SymlinkPolicy = .allow
    ) throws -> Data {
        guard maximumByteCount >= 0 else { throw ReadError.invalidMaximumSize }

        var flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC
        if symlinkPolicy == .reject { flags |= O_NOFOLLOW }
        let descriptor = url.path.withCString { Darwin.open($0, flags) }
        guard descriptor >= 0 else { throw ReadError.openFailed(errno) }
        defer { Darwin.close(descriptor) }

        let status = try regularFileStatus(
            descriptor: descriptor, maximumByteCount: maximumByteCount)
        return try readData(descriptor: descriptor, expectedByteCount: Int(status.st_size))
    }

    static func isMissingFileError(_ error: Error) -> Bool {
        guard let readError = error as? ReadError,
            case .openFailed(let code) = readError
        else { return false }
        return code == ENOENT || code == ENOTDIR
    }

    private static func regularFileStatus(
        descriptor: Int32, maximumByteCount: Int
    ) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw ReadError.inspectionFailed(errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw ReadError.notRegularFile
        }
        guard status.st_size >= 0, status.st_size <= off_t(maximumByteCount) else {
            throw ReadError.tooLarge(maximumByteCount: maximumByteCount)
        }
        return status
    }

    private static func readData(descriptor: Int32, expectedByteCount: Int) throws -> Data {
        var data = Data(count: expectedByteCount)
        let actualByteCount = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < expectedByteCount {
                let count = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedByteCount - offset,
                    off_t(offset))
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    throw ReadError.readFailed(errno)
                }
            }
            return offset
        }
        if actualByteCount < expectedByteCount {
            data.removeSubrange(actualByteCount..<expectedByteCount)
        }
        return data
    }

    private static func modificationDate(from status: stat) -> Date {
        let seconds = TimeInterval(status.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds + nanoseconds)
    }
}
