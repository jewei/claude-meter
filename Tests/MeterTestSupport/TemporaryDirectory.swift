import Foundation

/// A unique directory under the system temporary directory, removed by ``remove()``.
///
/// Use one per test: `let home = try TemporaryDirectory(); defer { home.remove() }`.
public struct TemporaryDirectory: Sendable {
    public let url: URL

    public init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeMeterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// A path inside the directory.
    public func path(_ relative: String) -> URL {
        url.appending(path: relative)
    }

    /// Writes text to a file, creating parent directories.
    @discardableResult
    public func write(_ text: String, to relative: String) throws -> URL {
        try write(Data(text.utf8), to: relative)
    }

    @discardableResult
    public func write(_ data: Data, to relative: String) throws -> URL {
        let file = path(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    public func makeDirectory(_ relative: String) throws -> URL {
        let directory = path(relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
