import ClaudeMeterCore
import Darwin
import Foundation

/// Shared reader/writer for a Claude Code `settings.json`. Both `StatuslineBridge`
/// (which manages `statusLine`) and `HookBridge` (which manages `hooks`) mutate the
/// same physical file, so the parse-with-typed-error and atomic pretty-printed
/// write live here once instead of being copied into each.
enum SettingsFile {
    private static let maximumFileBytes = 4 * 1_024 * 1_024

    enum ParseError: Error, LocalizedError {
        case invalidJSON
        case rootNotObject

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                "Claude Code settings.json is not valid JSON."
            case .rootNotObject:
                "Claude Code settings.json must contain a JSON object."
            }
        }
    }

    /// Reads + parses the file, returning `[:]` when it doesn't exist.
    static func read(at path: URL) throws -> [String: Any] {
        do {
            let data = try BoundedRegularFileReader.read(
                at: path, maximumByteCount: maximumFileBytes)
            return try parse(data)
        } catch  where BoundedRegularFileReader.isMissingFileError(error) {
            return [:]
        }
    }

    /// Parses settings JSON. `nil`/missing → `[:]`; empty or non-JSON →
    /// `.invalidJSON`; a non-object root → `.rootNotObject`.
    static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !data.isEmpty else { throw ParseError.invalidJSON }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParseError.invalidJSON
        }
        guard let settings = object as? [String: Any] else {
            throw ParseError.rootNotObject
        }
        return settings
    }

    /// Atomically writes settings as pretty-printed, sorted-key JSON (creating the
    /// parent directory if needed).
    static func write(_ settings: [String: Any], at path: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        let destination = try writeDestination(for: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    /// `Data.write(.atomic)` replaces a final symbolic link instead of its target.
    /// Resolve that link first so a deliberately linked settings file stays linked.
    private static func writeDestination(for path: URL) throws -> URL {
        var status = stat()
        let result = path.path.withCString { Darwin.lstat($0, &status) }
        guard result == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return path }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (status.st_mode & S_IFMT) == S_IFLNK else { return path }

        let rawDestination = try FileManager.default.destinationOfSymbolicLink(atPath: path.path)
        let destination =
            rawDestination.hasPrefix("/")
            ? URL(fileURLWithPath: rawDestination)
            : path.deletingLastPathComponent().appendingPathComponent(rawDestination)
        return destination.standardizedFileURL.resolvingSymlinksInPath()
    }
}
