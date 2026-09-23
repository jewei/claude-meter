import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Legacy attention hook migration")
struct LegacyAttentionHookMigrationTests {
    private typealias Migration = LegacyAttentionHookMigration

    private final class Fixture {
        let home: URL
        let defaults: UserDefaults
        private let suite = "LegacyAttentionMigration-\(UUID().uuidString)"

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }

        func write(_ settings: [String: Any], in name: String = ".claude") throws -> URL {
            let file = home.appendingPathComponent(name).appendingPathComponent("settings.json")
            try SettingsFile.write(settings, at: file)
            return file
        }

        func run(configuredDirs: [String] = []) throws {
            try Migration.runIfNeeded(
                configuredDirs: configuredDirs, home: home, defaults: defaults)
        }

        var completed: Bool { defaults.bool(forKey: Migration.completionKey) }
    }

    private func entry(_ command: String) -> [String: Any] {
        ["type": "command", "command": command]
    }

    private func ownedSettings(_ command: String = Migration.knownCommands[0]) -> [String: Any] {
        ["hooks": ["Stop": [["hooks": [entry(command)]]]]]
    }

    @Test func commandLiteralsMatchTheHistoricalVersions() {
        // Digests of the six exact raw strings read from ece8d08 and its ancestors.
        let expected = [
            "da99aa37718395e91940373f1bd8b5de525e26eea76a9f1d7076ddae76ee0752",
            "4d6956b3cf1591234af566baa26f61e1e0a0aacacc5f5bfc137e975712bde34e",
            "27ed92919293d37f6cd6208aaf5679d49c4b09a2b503b12d2c69dccbafe791bd",
            "4a5f58f2b47f3ca75b42269f763b8a259bda048cb650045296629fb8d0296af5",
            "962b2b0efd44987e3684e43b8cced4b028b1ba1edb6dc7671ed7583755082bf6",
            "00c103b636b7aa3dbfbddb70225e7f60f1c95cd7e6dd4e704ff4d96b07e3c22a",
        ]
        #expect(
            Migration.knownCommands.map {
                SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
            } == expected)
    }

    @Test(arguments: 0..<6)
    func removesEachKnownVersionFromAllManagedEvents(version: Int) throws {
        let fixture = try Fixture()
        let command = Migration.knownCommands[version]
        let statusline: [String: Any] = [
            "type": "command",
            "command": LegacyStatuslineMigration.knownSnippets[0] + " | my-status.sh",
            "refreshInterval": 1,
        ]
        let retained: [String: Any] = [
            "statusLine": statusline,
            "permissions": ["allow": ["Read"], "deny": ["Bash(rm *)"]],
            "model": "sonnet",
        ]
        var before = retained
        before["hooks"] = Dictionary(
            uniqueKeysWithValues: ["Stop", "Notification", "StopFailure"].map {
                ($0, [["hooks": [entry(command)]]])
            })
        let file = try fixture.write(before)

        try fixture.run()

        #expect(NSDictionary(dictionary: try SettingsFile.read(at: file)).isEqual(to: retained))
        #expect(fixture.completed)
        // A completed migration returns before any filesystem inspection.
        try FileManager.default.removeItem(at: fixture.home)
        try fixture.run()
    }

    @Test func mixedGroupsKeepUserCommandsMetadataAndOtherEvents() throws {
        let fixture = try Fixture()
        let own = Migration.knownCommands[0]
        let userEntries: [[String: Any]] = [
            ["type": "command", "command": "echo 'my Stop hook'", "timeout": 37, "async": true],
            entry(own + " "),  // Exact equality only, including whitespace.
            entry("echo ~/.claude-meter/events"),
            ["type": "prompt", "prompt": "Check the result"],
        ]
        let userGroup: [String: Any] = ["matcher": "*", "timeout": 51, "hooks": userEntries]
        var mixed = userGroup
        mixed["hooks"] = userEntries + Migration.knownCommands.map { entry($0) }
        let untouched: [String: Any] = [
            "hooks": [entry("my-permission.sh")], "matcher": "idle_prompt",
        ]
        let otherEvent = [["hooks": [entry(own)]]]
        let file = try fixture.write([
            "hooks": [
                "Stop": [mixed, ["hooks": []]], "Notification": [untouched],
                "StopFailure": [["hooks": [entry("my-failure.sh")]]],
                "PreToolUse": otherEvent, "SessionStart": [],
            ],
            "custom": ["nested": [1, 2, 3]],
        ])

        try fixture.run()

        let expected: [String: Any] = [
            "hooks": [
                "Stop": [userGroup, ["hooks": []]], "Notification": [untouched],
                "StopFailure": [["hooks": [entry("my-failure.sh")]]],
                "PreToolUse": otherEvent, "SessionStart": [],
            ],
            "custom": ["nested": [1, 2, 3]],
        ]
        #expect(NSDictionary(dictionary: try SettingsFile.read(at: file)).isEqual(to: expected))
    }

    @Test func userOnlySettingsAreNotRewritten() throws {
        let fixture = try Fixture()
        let file = try fixture.write([:])
        let bytes = Data(
            "{ \"hooks\": {\"Stop\": [{\"hooks\": [{\"type\":\"command\",\"command\":\"echo mine\"}]}]}, \"custom\":true }\n"
                .utf8)
        try bytes.write(to: file)
        let inode =
            try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber]
            as? NSNumber

        try fixture.run()

        #expect(try Data(contentsOf: file) == bytes)
        #expect(
            try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber]
                as? NSNumber == inode)
    }

    @Test func repeatedMigrationDoesNotWriteOrRecreateStorage() throws {
        let fixture = try Fixture()
        let file = try fixture.write(ownedSettings())
        try fixture.run()
        let bytes = try Data(contentsOf: file)
        let inode =
            try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber]
            as? NSNumber
        try fixture.run()
        // The cleanup is also idempotent if persistence was lost after the write.
        fixture.defaults.removeObject(forKey: Migration.completionKey)
        try fixture.run()
        #expect(try Data(contentsOf: file) == bytes)
        #expect(
            try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber]
                as? NSNumber == inode)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.home.appendingPathComponent(".claude-meter").path))
        #expect(fixture.completed)
    }

    @Test func missingSettingsAndDirectoriesAreHarmless() throws {
        let fixture = try Fixture()
        let directory = fixture.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixture.run(configuredDirs: [fixture.home.appendingPathComponent("missing").path])
        #expect(fixture.completed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(arguments: [
        "{broken", "[]", "{\"hooks\":[]}", "{\"hooks\":{\"Stop\":{}}}",
        "{\"hooks\":{\"Stop\":[\"invalid\"]}}", "{\"hooks\":{\"Stop\":[{}]}}",
        "{\"hooks\":{\"Stop\":[{\"hooks\":[\"invalid\"]}]}}",
    ])
    func malformedSettingsStayUnchangedAndIncomplete(raw: String) throws {
        let fixture = try Fixture()
        let file = try fixture.write([:])
        let bytes = Data(raw.utf8)
        try bytes.write(to: file)
        #expect(throws: (any Error).self) { try fixture.run() }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!fixture.completed)
    }

    @Test func malformedLaterEventPreventsPartialFileRewrite() throws {
        let fixture = try Fixture()
        let file = try fixture.write([
            "hooks": [
                "Stop": [["hooks": [entry(Migration.knownCommands[0])]]],
                "Notification": [["hooks": "invalid"]],
            ]
        ])
        let bytes = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { try fixture.run() }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!fixture.completed)
    }

    @Test func partialFailureCleansOtherDirectoriesAndRetries() throws {
        let fixture = try Fixture()
        let broken = try fixture.write([:])
        try Data("{bad".utf8).write(to: broken)
        let good = try fixture.write(ownedSettings(), in: ".claude-work")
        #expect(throws: (any Error).self) { try fixture.run() }
        #expect(try SettingsFile.read(at: good)["hooks"] == nil)
        #expect(!fixture.completed)

        try SettingsFile.write(ownedSettings(), at: broken)
        try fixture.run()
        #expect(try SettingsFile.read(at: broken)["hooks"] == nil)
        #expect(fixture.completed)
    }

    @Test func coversConfiguredDisabledAndCollidingAccountsOnly() throws {
        let fixture = try Fixture()
        let names = [".claude", ".claude-disabled", "custom/work", "another/work"]
        let files = try names.map { try fixture.write(ownedSettings(), in: $0) }
        let ignored = try ["unconfigured", ".claude-unrelated/nested", ".claudeother"].map {
            try fixture.write(ownedSettings(), in: $0)
        }
        let before = try ignored.map { try Data(contentsOf: $0) }
        let configured = files.suffix(2).map { $0.deletingLastPathComponent().path }
        try fixture.run(configuredDirs: configured + configured)
        for file in files { #expect(try SettingsFile.read(at: file)["hooks"] == nil) }
        for (file, bytes) in zip(ignored, before) { #expect(try Data(contentsOf: file) == bytes) }
        #expect(fixture.completed)
    }

    @Test func unreadableScanOrNonDirectoryConfigCannotComplete() throws {
        let fixture = try Fixture()
        let file = fixture.home.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        #expect(throws: (any Error).self) { try fixture.run(configuredDirs: [file.path]) }
        #expect(!fixture.completed)
        #expect(throws: (any Error).self) {
            try Migration.runIfNeeded(configuredDirs: [], home: file, defaults: fixture.defaults)
        }
        #expect(!fixture.completed)
    }

    @Test(arguments: [false, true])
    func unsafeSettingsCannotComplete(oversized: Bool) throws {
        let fixture = try Fixture()
        let file = try fixture.write([:])
        try FileManager.default.removeItem(at: file)
        if oversized {
            try Data(repeating: 32, count: 4 * 1_024 * 1_024 + 1).write(to: file)
        } else {
            #expect(file.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
        }
        #expect(throws: (any Error).self) { try fixture.run() }
        #expect(!fixture.completed)
    }

    @Test func atomicCleanupPreservesSettingsSymlink() throws {
        let fixture = try Fixture()
        let file = try fixture.write(ownedSettings())
        let target = file.deletingLastPathComponent().appendingPathComponent("shared.json")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(
            atPath: file.path, withDestinationPath: "shared.json")
        try fixture.run()
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == "shared.json")
        #expect(try SettingsFile.read(at: target)["hooks"] == nil)
    }

    @Test func removesEventFilesAndPreservesSessionData() throws {
        let fixture = try Fixture()
        _ = try fixture.write(ownedSettings())
        let dataRoot = fixture.home.appendingPathComponent(".claude-meter")
        for relative in [
            "events/claude/s.Stop.123.json", "events/claude/.tmp.123",
            "events/old.json", "sessions/claude/s.json", "statusline.json",
        ] {
            let file = dataRoot.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(relative.utf8).write(to: file)
        }
        try fixture.run()
        for relative in [
            "events/claude/s.Stop.123.json", "events/claude/.tmp.123", "events/old.json",
        ] {
            #expect(
                !FileManager.default.fileExists(
                    atPath: dataRoot.appendingPathComponent(relative).path))
        }
        for relative in ["sessions/claude/s.json", "statusline.json"] {
            #expect(
                try Data(contentsOf: dataRoot.appendingPathComponent(relative))
                    == Data(relative.utf8))
        }
    }

    @Test(arguments: [".claude-meter", ".claude-meter/events", ".claude-meter/events/claude"])
    func eventCleanupCannotFollowDirectoryLinks(linkPath: String) throws {
        let fixture = try Fixture()
        let outside = fixture.home.appendingPathComponent("outside")
        for relative in ["events/claude/keep.json", "claude/keep.json", "keep.json"] {
            let file = outside.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(relative.utf8).write(to: file)
        }
        let link = fixture.home.appendingPathComponent(linkPath)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try fixture.run()
        for relative in ["events/claude/keep.json", "claude/keep.json", "keep.json"] {
            #expect(
                try Data(contentsOf: outside.appendingPathComponent(relative))
                    == Data(relative.utf8))
        }
    }
}
