import Foundation

/// Shared reader/writer for a Claude Code `settings.json`. Both `StatuslineBridge`
/// (which manages `statusLine`) and `HookBridge` (which manages `hooks`) mutate the
/// same physical file, so the parse-with-typed-error and atomic pretty-printed
/// write live here once instead of being copied into each.
enum SettingsFile {
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
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        return try parse(Data(contentsOf: path))
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
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }
}
