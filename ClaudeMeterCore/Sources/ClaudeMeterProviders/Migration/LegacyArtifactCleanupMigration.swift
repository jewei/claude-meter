import Darwin
import Foundation

/// Removes exact obsolete app files after their compatibility migrations complete.
/// Call off-main. This never reads file contents or removes directories/defaults domains.
public enum LegacyArtifactCleanupMigration {
    static let completionKey = "didCleanupObsoleteArtifacts.v1"
    static let prerequisites = [
        LegacyAttentionHookMigration.completionKey,
        LegacyStatuslineMigration.completionKey,
        "didImportLegacyAppGroupSnapshot.v1",
    ]

    private static let paths = [
        "Library/Application Support/ClaudeMeter/cost-usage-cache.json",
        "Library/Caches/com.jewei.claudemeter/models-dev-pricing-v1.json",
        "Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter/main-meter.json",
        "Library/Application Support/ClaudeMeter/main-meter.json",
        "Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter/current.json",
        "Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter/last-error.json",
        "Library/Application Support/ClaudeMeter/usage-history.jsonl",
    ]

    enum CleanupError: Error, LocalizedError {
        case prerequisitesIncomplete

        var errorDescription: String? {
            "Obsolete file cleanup requires the earlier upgrade migrations to complete."
        }
    }

    public static func runIfNeeded() throws {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }
        // Hosted tests must never remove artifacts from the installed user's home.
        guard !KeychainGateway.testFrameworkIsLoaded() else { return }
        try runIfNeeded(home: FileManager.default.homeDirectoryForCurrentUser, defaults: .standard)
    }

    static func runIfNeeded(home: URL, defaults: UserDefaults) throws {
        guard !defaults.bool(forKey: completionKey) else { return }
        guard prerequisites.allSatisfy({ defaults.bool(forKey: $0) }) else {
            throw CleanupError.prerequisitesIncomplete
        }
        let root = try BoundedRegularFileReader.AnchoredDirectory(opening: home)
        var firstError: Error?
        for path in paths {
            do {
                try removeFile(path: path, root: root, home: home)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        defaults.set(true, forKey: completionKey)
    }

    private static func removeFile(
        path: String, root: BoundedRegularFileReader.AnchoredDirectory, home: URL
    ) throws {
        let components = path.split(separator: "/").map(String.init)
        var directories = [root]
        func checkDirectories() throws {
            guard root.stillNamesDirectory(at: home),
                components.prefix(directories.count - 1).enumerated().allSatisfy({
                    index, component in
                    directories[index].stillContainsDirectory(
                        directories[index + 1], named: component)
                })
            else { throw BoundedRegularFileReader.ReadError.fileChanged }
        }
        for name in components.dropLast() {
            do {
                directories.append(try directories.last!.directory(named: name))
            } catch BoundedRegularFileReader.ReadError.openFailed(ENOENT) {
                try checkDirectories()
                return  // A missing parent proves absence only under the unchanged root.
            }
        }
        let parent = directories.last!
        let name = components.last!
        let entry: BoundedRegularFileReader.AnchoredDirectory.Entry
        do {
            entry = try parent.entry(named: name)
        } catch BoundedRegularFileReader.ReadError.inspectionFailed(ENOENT) {
            try checkDirectories()
            return
        }
        guard entry.isRegularFile else { throw BoundedRegularFileReader.ReadError.notRegularFile }
        try checkDirectories()
        guard parent.unlinkEntry(named: name, ifUnchangedSince: entry)
        else { throw BoundedRegularFileReader.ReadError.fileChanged }
    }
}
