import Darwin
import Foundation

/// Reads small files that other apps own, such as auth and settings JSON.
///
/// `Data(contentsOf:)` can block forever on a FIFO and reads files of any size. These reads
/// open without blocking, accept only regular files, and stop at a size limit. Symbolic links
/// are followed, because users link config files. Call them through ``BlockingIO``.
public enum LocalFile {
    public enum ReadError: Error, Equatable, LocalizedError, Sendable {
        case notFound
        case notRegularFile
        case tooLarge(limit: Int)
        case unreadable(errno: Int32)

        public var errorDescription: String? {
            switch self {
            case .notFound: "The file does not exist."
            case .notRegularFile: "The path is not a regular file."
            case .tooLarge(let limit): "The file is larger than \(limit) bytes."
            case .unreadable(let code):
                "The file could not be read (\(String(cString: strerror(code))))."
            }
        }
    }

    /// The full contents of a regular file of at most `maxBytes`.
    public static func read(_ url: URL, maxBytes: Int) throws(ReadError) -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ENOENT || errno == ENOTDIR ? .notFound : .unreadable(errno: errno)
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegularFile }
        guard info.st_size <= maxBytes else { throw .tooLarge(limit: maxBytes) }

        let data = try readAll(descriptor, from: 0, maxBytes: maxBytes)
        // A file that grew after fstat must not pass the limit.
        var probe: UInt8 = 0
        if data.count == maxBytes, pread(descriptor, &probe, 1, Int64(maxBytes)) > 0 {
            throw .tooLarge(limit: maxBytes)
        }
        return data
    }

    /// Bytes `[offset, offset + count)` of an open regular file. Returns fewer bytes at the end
    /// of the file.
    public static func read(
        _ descriptor: Int32, from offset: Int64, count: Int
    ) throws(ReadError) -> Data {
        try readAll(descriptor, from: offset, maxBytes: count)
    }

    private static func readAll(
        _ descriptor: Int32, from offset: Int64, maxBytes: Int
    ) throws(ReadError) -> Data {
        var data = Data()
        var position = offset
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while data.count < maxBytes {
            let wanted = min(chunkSize, maxBytes - data.count)
            let count = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, wanted, position)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable(errno: errno)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            position += Int64(count)
        }
        return data
    }

    /// Whether a regular file exists at `url`, following links. Never reads the contents.
    public static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// Whether a directory exists at `url`, following links.
    public static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
