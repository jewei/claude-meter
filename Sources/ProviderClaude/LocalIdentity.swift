import Darwin
import Foundation
import MeterDomain
import MeterPlatform

/// The login that Claude Code recorded in a config dir's `.claude.json`, read without network.
struct LocalIdentity: Sendable, Equatable {
    /// The outcome of reading an identity file.
    enum Read: Sendable, Equatable {
        case found(LocalIdentity)
        /// No file, or a complete file that names no login.
        case absent
        /// The file could not be read now, for example while Claude Code writes it. Proves
        /// nothing about the login.
        case unreadable
    }

    /// Claude Code keeps per-project state in this file too, so it can be very large. The read
    /// scans the file in chunks and keeps only the `oauthAccount` object.
    static let maxFileBytes = 256 * 1024 * 1024
    private static let chunkBytes = 256 * 1024

    let accountUUID: String?
    let organizationUUID: String?
    /// `organizationRateLimitTier`, else `userRateLimitTier`.
    let rateLimitTier: String?

    /// A stable owner for retention, or nil when the file names no account.
    var owner: AccountOwner? {
        guard let accountUUID, !accountUUID.isEmpty else { return nil }
        return .identity(Digest.sha256(parts: ["claude", accountUUID, organizationUUID ?? ""]))
    }

    /// The identity file of a config dir. For `~/.claude` Claude Code writes `~/.claude.json`
    /// in the home folder, not inside the dir.
    static func file(for directory: URL, home: URL) -> URL {
        let defaultDirectory = home.appending(path: ".claude", directoryHint: .isDirectory)
        if directory.standardizedFileURL.path == defaultDirectory.standardizedFileURL.path {
            return home.appending(path: ".claude.json")
        }
        return directory.appending(path: ".claude.json")
    }

    /// Reads the file. Blocking: call through ``BlockingIO``. A missing file, or something
    /// other than a regular file, is absent. A file that ends before its root object does, is
    /// larger than `maxBytes`, or fails to read is unreadable.
    static func read(
        _ file: URL, maxBytes: Int = maxFileBytes, cancellation: BlockingIO.Cancellation? = nil
    ) -> Read {
        // The same safe open as `LocalFile.read`: no blocking on a FIFO, regular files only.
        let descriptor = open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .unreadable }
        guard info.st_mode & S_IFMT == S_IFREG else { return .absent }
        guard info.st_size <= maxBytes else { return .unreadable }

        var scanner = OAuthAccountScanner()
        var offset: Int64 = 0
        while !scanner.isFinished {
            if cancellation?.isCancelled == true { return .unreadable }
            guard let chunk = try? LocalFile.read(descriptor, from: offset, count: chunkBytes)
            else { return .unreadable }
            if chunk.isEmpty { break }
            offset += Int64(chunk.count)
            // The file grew past the limit while it was read.
            guard offset <= maxBytes else { return .unreadable }
            scanner.feed(chunk)
        }
        return result(of: scanner)
    }

    /// Reads identity file contents that are already in memory.
    static func parse(_ data: Data) -> Read {
        var scanner = OAuthAccountScanner()
        scanner.feed(data)
        return result(of: scanner)
    }

    private static func result(of scanner: OAuthAccountScanner) -> Read {
        if let object = scanner.object {
            guard let account = try? JSONSerialization.jsonObject(with: object) as? [String: Any]
            else { return .unreadable }
            return .found(
                LocalIdentity(
                    accountUUID: account["accountUuid"] as? String,
                    organizationUUID: account["organizationUuid"] as? String,
                    rateLimitTier: account["organizationRateLimitTier"] as? String
                        ?? account["userRateLimitTier"] as? String))
        }
        // A file that is not a JSON object stays that way; a file cut short is being written.
        return scanner.isComplete || scanner.isMalformed ? .absent : .unreadable
    }
}
