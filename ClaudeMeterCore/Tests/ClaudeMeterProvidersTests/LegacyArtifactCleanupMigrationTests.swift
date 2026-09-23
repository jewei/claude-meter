import ClaudeMeterCore
import Darwin
import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Legacy artifact cleanup")
struct LegacyArtifactCleanupMigrationTests {
    private typealias Migration = LegacyArtifactCleanupMigration
    private static let app = "Library/Application Support/ClaudeMeter/"
    private static let group =
        "Library/Group Containers/group.com.jewei.claudemeter/Library/Application Support/ClaudeMeter/"
    private static let artifacts = [
        app + "cost-usage-cache.json",
        "Library/Caches/com.jewei.claudemeter/models-dev-pricing-v1.json",
        group + "main-meter.json", app + "main-meter.json", group + "current.json",
        group + "last-error.json",
        app + "usage-history.jsonl",
    ]

    private final class Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "LegacyArtifactCleanup-\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        func completePrerequisites() {
            for key in Migration.prerequisites { defaults.set(true, forKey: key) }
        }
        @discardableResult func write(_ path: String, bytes: Data = Data("fixture".utf8)) throws
            -> URL
        {
            let file = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            return file
        }
        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path)
        }
        func run() throws { try Migration.runIfNeeded(home: home, defaults: defaults) }
        var complete: Bool { defaults.bool(forKey: Migration.completionKey) }
        func importSnapshot() throws -> SnapshotStore {
            let store = try SnapshotStore.applicationSupport(
                in: home.appendingPathComponent("Library/Application Support"))
            try store.importLegacyAppGroupSnapshotIfNeeded(home: home, defaults: defaults)
            return store
        }
    }

    private func snapshot(at date: Date = Date(timeIntervalSince1970: 1_800_000_000))
        -> ClaudeUsageSnapshot
    {
        ClaudeUsageSnapshot(
            parserVersion: "oauth-api-1.0", createdAt: date, lastSuccessfulPollAt: date,
            source: SourceInfo(cliPath: "oauth", command: "usage"),
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 35)),
            state: SnapshotState(status: .ok, severity: .normal))
    }

    @Test func removesOnlyExactArtifactsAndPreservesSettingsAndNeighbors() throws {
        let f = try Fixture()
        f.completePrerequisites()
        // Cleanup must not decode obsolete analytics models or malformed cache contents.
        for path in Self.artifacts { try f.write(path, bytes: Data([0xFF, 0x00])) }
        let retained = [
            Self.app + "current.json", Self.app + "last-error.json", Self.app + "notes.json",
            Self.app + "cost-usage-cache.json.backup",
            "Library/Caches/com.jewei.claudemeter/models-dev-pricing-v2.json",
            Self.group + "unknown.json",
            "Library/Preferences/group.com.jewei.claudemeter.plist",
            "Library/Group Containers/group.com.jewei.claudemeter/Library/Preferences/group.com.jewei.claudemeter.plist",
            ".claude/settings.json", ".claude-meter/keep.txt", ".codex/auth.json",
        ]
        for path in retained { try f.write(path, bytes: Data(path.utf8)) }
        f.defaults.set("preserve", forKey: "menuBarAccount")

        try f.run()

        #expect(f.complete)
        for path in Self.artifacts { #expect(!f.exists(path)) }
        for path in retained {
            #expect(try Data(contentsOf: f.home.appendingPathComponent(path)) == Data(path.utf8))
        }
        #expect(f.defaults.string(forKey: "menuBarAccount") == "preserve")
        for key in Migration.prerequisites { #expect(f.defaults.bool(forKey: key)) }
        #expect(f.exists(Self.group))  // No container/directory removal.
    }

    @Test func absentFilesCompleteWithoutCreatingDirectoriesAndSecondRunDoesNoIO() throws {
        let f = try Fixture()
        f.completePrerequisites()
        try f.run()
        #expect(f.complete)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.home.path).isEmpty)
        try FileManager.default.removeItem(at: f.home)
        try f.run()  // Must return before it attempts to open the missing home.
        #expect(f.complete)
    }

    @Test func deletionIsIdempotentEvenIfTheCompletionFlagWasNotSaved() throws {
        let f = try Fixture()
        f.completePrerequisites()
        for path in Self.artifacts { try f.write(path) }
        try f.run()
        f.defaults.removeObject(forKey: Migration.completionKey)
        try f.run()
        #expect(f.complete)
        for path in Self.artifacts { #expect(!f.exists(path)) }
    }

    @Test(arguments: Migration.prerequisites)
    func incompletePrerequisitePreventsAllDeletion(key: String) throws {
        let f = try Fixture()
        f.completePrerequisites()
        f.defaults.removeObject(forKey: key)
        for path in Self.artifacts { try f.write(path) }
        #expect(throws: Migration.CleanupError.self) { try f.run() }
        #expect(!f.complete)
        for path in Self.artifacts { #expect(f.exists(path)) }
    }

    @Test func partialFilesystemFailureLeavesCleanupRetryable() throws {
        let f = try Fixture()
        f.completePrerequisites()
        for path in Self.artifacts { try f.write(path) }
        let blocked = f.home.appendingPathComponent(Self.group + "current.json")
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        let child = blocked.appendingPathComponent("unrelated")
        try Data("keep".utf8).write(to: child)

        #expect(throws: (any Error).self) { try f.run() }
        #expect(!f.complete)
        #expect(try Data(contentsOf: child) == Data("keep".utf8))
        for path in Self.artifacts where path != Self.group + "current.json" {
            #expect(!f.exists(path))
        }
        // The user repairs the unexpected path; the next launch can finish.
        try FileManager.default.removeItem(at: blocked)
        try f.write(Self.group + "current.json")
        try f.run()
        #expect(f.complete)
        #expect(!f.exists(Self.group + "current.json"))
    }

    @Test(arguments: ["Library", "Library/Application Support", Self.group.dropLast().description])
    func directoryLinksCannotRedirectDeletion(path: String) throws {
        let f = try Fixture()
        f.completePrerequisites()
        let outside = f.home.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("current.json")
        try Data("keep".utf8).write(to: file)
        let link = f.home.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: (any Error).self) { try f.run() }
        #expect(!f.complete)
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
    }

    @Test(.enabled(if: geteuid() != 0))
    func permissionFailureRetriesWithoutRemovingTheDirectory() throws {
        let f = try Fixture()
        f.completePrerequisites()
        let file = try f.write(Self.artifacts[0])
        let parent = file.deletingLastPathComponent()
        #expect(chmod(parent.path, 0o500) == 0)
        defer { _ = chmod(parent.path, 0o700) }
        #expect(throws: (any Error).self) { try f.run() }
        #expect(!f.complete)
        #expect(f.exists(Self.artifacts[0]))
        #expect(chmod(parent.path, 0o700) == 0)
        try f.run()
        #expect(f.complete)
        #expect(!f.exists(Self.artifacts[0]))
        #expect(f.exists(Self.app))
    }

    @Test func finalLinksAndFIFOsAreNotFollowedOrRemoved() throws {
        let f = try Fixture()
        f.completePrerequisites()
        let target = try f.write("keep.txt")
        let link = try f.write(Self.artifacts[0])
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let fifo = try f.write(Self.artifacts[1])
        try FileManager.default.removeItem(at: fifo)
        #expect(mkfifo(fifo.path, 0o600) == 0)

        #expect(throws: (any Error).self) { try f.run() }
        #expect(!f.complete)
        #expect(try Data(contentsOf: target) == Data("fixture".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        var status = stat()
        #expect(lstat(fifo.path, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFIFO)
    }

    @Test func failedImportKeepsSourceUntilRetrySucceeds() throws {
        let f = try Fixture()
        f.completePrerequisites()
        f.defaults.removeObject(forKey: "didImportLegacyAppGroupSnapshot.v1")
        let legacy = try f.write(Self.group + "current.json", bytes: Data("{bad".utf8))
        try f.write(Self.app + "cost-usage-cache.json")
        #expect(throws: (any Error).self) { try f.importSnapshot() }
        #expect(throws: Migration.CleanupError.self) { try f.run() }
        #expect(try Data(contentsOf: legacy) == Data("{bad".utf8))
        #expect(f.exists(Self.app + "cost-usage-cache.json"))
        #expect(!f.complete)

        let expected = snapshot()
        try SnapshotStore(directory: legacy.deletingLastPathComponent()).writeLatest(expected)
        let current = try f.importSnapshot()
        #expect(try current.readLatest() == expected)
        try f.run()
        #expect(f.complete)
        #expect(!f.exists(Self.group + "current.json"))
        #expect(try current.readLatest() == expected)
    }

    @Test func failedImportWriteCannotLoseTheOnlySnapshot() throws {
        let f = try Fixture()
        f.completePrerequisites()
        f.defaults.removeObject(forKey: "didImportLegacyAppGroupSnapshot.v1")
        let legacy = try f.write(Self.group + "current.json")
        let expected = snapshot()
        try SnapshotStore(directory: legacy.deletingLastPathComponent()).writeLatest(expected)
        let current = SnapshotStore(directory: f.home.appendingPathComponent(Self.app))
        #expect(throws: (any Error).self) {
            try current.importLegacyAppGroupSnapshotIfNeeded(home: f.home, defaults: f.defaults)
        }
        #expect(throws: Migration.CleanupError.self) { try f.run() }
        #expect(f.exists(Self.group + "current.json"))
        let imported = try f.importSnapshot()
        try f.run()
        #expect(try imported.readLatest() == expected)
    }

    @Test func newerCurrentObservationSurvivesImportAndCleanup() throws {
        let f = try Fixture()
        f.completePrerequisites()
        f.defaults.removeObject(forKey: "didImportLegacyAppGroupSnapshot.v1")
        let legacy = try f.write(Self.group + "current.json")
        try SnapshotStore(directory: legacy.deletingLastPathComponent()).writeLatest(snapshot())
        let currentURL = try f.write(Self.app + "current.json")
        let current = SnapshotStore(directory: currentURL.deletingLastPathComponent())
        let newer = snapshot(at: Date(timeIntervalSince1970: 1_800_000_060))
        try current.writeLatest(newer)
        _ = try f.importSnapshot()
        try f.run()
        #expect(try current.readLatest() == newer)
        #expect(!f.exists(Self.group + "current.json"))
    }

    @Test func existingMigrationsKeepTheirOwnershipAndRunBeforeFinalCleanup() throws {
        let f = try Fixture()
        let settingsURL = f.home.appendingPathComponent(".claude/settings.json")
        let userHook = ["type": "command", "command": "my-hook"]
        try SettingsFile.write(
            [
                "hooks": [
                    "Stop": [
                        [
                            "hooks": [
                                userHook,
                                [
                                    "type": "command",
                                    "command": LegacyAttentionHookMigration.knownCommands[0],
                                ],
                            ]
                        ]
                    ]
                ],
                "statusLine": [
                    "command": LegacyStatuslineMigration.knownSnippets[0] + " | my-status",
                    "refreshInterval": 1,
                ],
                "model": "keep",
            ], at: settingsURL)
        let captures = [
            ".claude-meter/statusline.json", ".claude-meter/.sl-123",
            ".claude-meter/sessions/old.json", ".claude-meter/sessions/claude/session.json",
            ".claude-meter/sessions/claude/.tmp.123",
        ]
        for path in captures { try f.write(path) }
        let event = ".claude-meter/events/claude/session.Stop.123.json"
        try f.write(event)
        let unrelated = try f.write(".claude-meter/keep.json")
        try f.write(Self.artifacts[0])

        try LegacyAttentionHookMigration.runIfNeeded(
            configuredDirs: [], home: f.home, defaults: f.defaults)
        #expect(!f.exists(event))
        for path in captures { #expect(f.exists(path)) }
        try LegacyStatuslineMigration.runIfNeeded(
            configuredDirs: [], home: f.home, defaults: f.defaults)
        for path in captures { #expect(!f.exists(path)) }
        let settingsAfter = try Data(contentsOf: settingsURL)
        let settings = try SettingsFile.read(at: settingsURL)
        #expect(settings["model"] as? String == "keep")
        #expect((settings["statusLine"] as? [String: Any])?["command"] as? String == "my-status")
        #expect(
            NSDictionary(dictionary: settings["hooks"] as! [String: Any]).isEqual(to: [
                "Stop": [["hooks": [userHook]]]
            ]))

        _ = try f.importSnapshot()  // No source is also a successful import attempt.
        // The final cleanup must not re-enter the capture directories or rewrite settings.
        let marker = try f.write(".claude-meter/sessions/keep-after-migration.txt")
        try f.run()
        #expect(f.complete)
        #expect(!f.exists(Self.artifacts[0]))
        #expect(try Data(contentsOf: settingsURL) == settingsAfter)
        #expect(try Data(contentsOf: unrelated) == Data("fixture".utf8))
        #expect(try Data(contentsOf: marker) == Data("fixture".utf8))
    }

    @Test func startupPreparationSharesTheAcceptedWriteQueue() async throws {
        let f = try Fixture()
        let store = ClaudeReadingStore(directory: f.home.appendingPathComponent(Self.app))
        let expected = snapshot()
        store.enqueue(expected, error: nil)
        try await store.importLegacySnapshotIfNeeded()
        #expect(await store.read() == expected)
        #expect(!f.defaults.bool(forKey: "didImportLegacyAppGroupSnapshot.v1"))
    }
}
