import Darwin
import Foundation

/// File operations used only by the legacy Claude integration migrations.
enum LegacyClaudeFiles {
    /// Use the old discovery scope, without hiding inspection failures or
    /// discarding paths with equal account keys. Either path may have been managed
    /// before the user's configured-path selection changed.
    static func configDirectories(home: URL, configuredDirs: [String]) throws -> [URL] {
        let children = try FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil)
        var candidates = [home.appendingPathComponent(".claude")]
        for child in children where child.lastPathComponent.hasPrefix(".claude-") {
            guard let fileMode = try mode(at: child), fileMode & S_IFMT == S_IFDIR else { continue }
            if try mode(at: child.appendingPathComponent("settings.json")) != nil
                || mode(at: child.appendingPathComponent("projects")) != nil
            {
                candidates.append(child)
            }
        }
        candidates += configuredDirs.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        var seen = Set<String>()
        return try candidates.filter { directory in
            guard let mode = try mode(at: directory) else { return false }
            guard mode & S_IFMT == S_IFDIR else {
                throw BoundedRegularFileReader.ReadError.notDirectory
            }
            return seen.insert(directory.resolvingSymlinksInPath().standardizedFileURL.path)
                .inserted
        }
    }

    private static func mode(at url: URL) throws -> mode_t? {
        var status = stat()
        guard url.path.withCString({ Darwin.fstatat(AT_FDCWD, $0, &status, 0) }) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status.st_mode
    }

    static func clearManagedSubdirectory(named name: String, in rootURL: URL) throws {
        try withRoot(rootURL) { root in
            let child: BoundedRegularFileReader.AnchoredDirectory
            do { child = try root.directory(named: name) } catch  where isAbsent(error) { return }
            func intact() -> Bool {
                root.stillNamesDirectory(at: rootURL)
                    && root.stillContainsDirectory(child, named: name)
            }
            for entryName in try child.entryNames() {
                if let account = try? child.directory(named: entryName) {
                    for file in try account.entryNames() {
                        let entry = try account.entry(named: file)
                        guard intact(), child.stillContainsDirectory(account, named: entryName),
                            account.unlinkEntry(named: file, ifUnchangedSince: entry)
                        else { throw BoundedRegularFileReader.ReadError.fileChanged }
                    }
                } else {
                    let entry = try child.entry(named: entryName)
                    guard intact(), child.unlinkEntry(named: entryName, ifUnchangedSince: entry)
                    else { throw BoundedRegularFileReader.ReadError.fileChanged }
                }
            }
        }
    }

    static func clearStatuslineFiles(in rootURL: URL) throws {
        try clearManagedSubdirectory(named: "sessions", in: rootURL)
        try withRoot(rootURL) { root in
            for name in try root.entryNames()
            where name == "statusline.json"
                || (name.hasPrefix(".sl-") && name.count > 4
                    && name.dropFirst(4).utf8.allSatisfy { (48...57).contains($0) })
            {
                let entry = try root.entry(named: name)
                guard root.stillNamesDirectory(at: rootURL),
                    root.unlinkEntry(named: name, ifUnchangedSince: entry)
                else { throw BoundedRegularFileReader.ReadError.fileChanged }
            }
        }
    }

    private static func isAbsent(_ error: Error) -> Bool {
        guard case BoundedRegularFileReader.ReadError.openFailed(let code) = error else {
            return false
        }
        return code == ENOENT
    }

    private static func withRoot(
        _ url: URL, operation: (BoundedRegularFileReader.AnchoredDirectory) throws -> Void
    ) throws {
        let root: BoundedRegularFileReader.AnchoredDirectory
        do { root = try .init(opening: url) } catch  where isAbsent(error) { return }
        try operation(root)
    }
}
