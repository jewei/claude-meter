import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Legacy statusline migration")
struct LegacyStatuslineMigrationTests {
    private typealias Migration = LegacyStatuslineMigration

    private final class Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "LegacyStatusline-\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        func write(_ settings: [String: Any], dir: String = ".claude") throws -> URL {
            let url = home.appendingPathComponent(dir).appendingPathComponent("settings.json")
            try SettingsFile.write(settings, at: url)
            return url
        }
        func run(_ configured: [String] = []) throws {
            try Migration.runIfNeeded(configuredDirs: configured, home: home, defaults: defaults)
        }
        var complete: Bool { defaults.bool(forKey: Migration.completionKey) }
    }

    @Test func literalsMatchGitHistory() {
        let expected = [
            "c95c0b7db116e666bb58f44f2ddc72ed75731d31be507cef9b6dd5407dec59aa",
            "1593c3c8e22552a79ca992d18fe065ccd32ad7b02b82e47cc38296b32a117a23",
            "9787117a1108201f63a50938f958ef8237831dbeb3f552929aef660ef8669439",
            "e80d2ace0651569e757f45452d3cbbdf8bf2ef8a3308923e0b14987ebca8b60e",
            "cb88be5b6d81b539f8f1031f369004a0986adc001ad2306f113a23d85b54a2f8",
        ]
        #expect(
            Migration.knownSnippets.map {
                SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
            } == expected)
    }

    @Test(arguments: 0..<5)
    func removesExactHistoricalPrefixesAndPreservesUserCommand(variant: Int) throws {
        let fixture = try Fixture()
        let userCommand = #"printf '%s' "$HOME" | my-status --format='a | b'"#
        let retained: [String: Any] = [
            "statusLine": [
                "type": "command", "command": userCommand, "refreshInterval": 1,
                "padding": 3, "custom": ["nested": true],
            ],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "my-hook"]]]]],
            "model": "sonnet", "permissions": ["allow": ["Read"]],
        ]
        var settings = retained
        var status = settings["statusLine"] as! [String: Any]
        status["command"] = Migration.knownSnippets[variant] + " | " + userCommand
        settings["statusLine"] = status
        let file = try fixture.write(settings)
        try fixture.run()
        #expect(NSDictionary(dictionary: try SettingsFile.read(at: file)).isEqual(to: retained))
        #expect(fixture.complete)
        let bytes = try Data(contentsOf: file)
        fixture.defaults.removeObject(forKey: Migration.completionKey)
        try fixture.run()
        #expect(try Data(contentsOf: file) == bytes)
        // Completion prevents even directory inspection on the next launch.
        try FileManager.default.removeItem(at: fixture.home)
        try fixture.run()
    }

    @Test(arguments: 0..<5)
    func removesStandaloneCommandsWithoutChangingInterval(variant: Int) throws {
        for suffix in ["", " > /dev/null"] {
            let fixture = try Fixture()
            let file = try fixture.write([
                "statusLine": [
                    "type": "command",
                    "command": Migration.knownSnippets[variant] + suffix, "refreshInterval": 17,
                ]
            ])
            try fixture.run()
            let status = try #require(SettingsFile.read(at: file)["statusLine"] as? [String: Any])
            #expect(status["command"] as? String == "")
            #expect(status["refreshInterval"] as? Int == 17)
        }
    }

    @Test func repeatedPrefixesAreRemovedButLookalikesAreUnchanged() throws {
        let chain = Migration.knownSnippets.joined(separator: " | ") + " | user-command"
        #expect(Migration.removingKnownPrefixes(from: chain) == "user-command")
        for command in [
            "echo ~/.claude-meter/statusline.json", " " + Migration.knownSnippets[0],
            Migration.knownSnippets[0] + " ; my-command",
            "my-command | " + Migration.knownSnippets[0],
        ] {
            let fixture = try Fixture()
            let file = try fixture.write(["statusLine": ["command": command]])
            let bytes = try Data(contentsOf: file)
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            try fixture.run()
            #expect(try Data(contentsOf: file) == bytes)
            #expect(
                try file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate == modified)
        }
    }

    @Test func missingSettingsAreHarmlessAndNotCreated() throws {
        let fixture = try Fixture()
        let dir = fixture.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try fixture.run()
        #expect(fixture.complete)
        #expect(
            !FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("settings.json").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.home.appendingPathComponent(".claude-meter").path))
    }

    @Test(arguments: [
        "broken JSON", "[]", "{\"statusLine\":42}", "{\"statusLine\":{\"command\":[]}}",
    ])
    func malformedSettingsRetryWithoutDestructiveRewrite(contents: String) throws {
        let fixture = try Fixture()
        let bad = try fixture.write([:])
        let bytes = Data(contents.utf8)
        try bytes.write(to: bad)
        let good = try fixture.write(
            ["statusLine": ["command": Migration.knownSnippets[0]]], dir: ".claude-work")
        #expect(throws: (any Error).self) { try fixture.run() }
        #expect(!fixture.complete)
        #expect(try Data(contentsOf: bad) == bytes)
        #expect(
            (try SettingsFile.read(at: good)["statusLine"] as? [String: Any])?["command"] as? String
                == "")
        try SettingsFile.write([:], at: bad)
        try fixture.run()
        #expect(fixture.complete)
    }

    @Test func includesConfiguredAndDisabledDirectoriesWithCollidingKeys() throws {
        let fixture = try Fixture()
        let names = [".claude", ".claude-work", "custom/.claude-work", "custom/account"]
        let files = try names.map {
            try fixture.write(["statusLine": ["command": Migration.knownSnippets[1]]], dir: $0)
        }
        fixture.defaults.set(["claude-work"], forKey: "disabledAccountKeys")
        try fixture.run(names.suffix(2).map { fixture.home.appendingPathComponent($0).path })
        for file in files {
            #expect(
                (try SettingsFile.read(at: file)["statusLine"] as? [String: Any])?["command"]
                    as? String == "")
        }
        #expect(fixture.complete)
    }

    @Test func settingsSymlinkAndUnrelatedDataRemain() throws {
        let fixture = try Fixture()
        let file = try fixture.write([
            "statusLine": ["command": Migration.knownSnippets[0] + " | user"]
        ])
        let target = file.deletingLastPathComponent().appendingPathComponent("shared.json")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(
            atPath: file.path, withDestinationPath: "shared.json")
        let root = fixture.home.appendingPathComponent(".claude-meter")
        for name in [
            "statusline.json", ".sl-123", "sessions/old.json", "sessions/claude/session.json",
            "sessions/claude/.tmp.123", "keep.json",
        ] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: url)
        }
        try fixture.run()
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == "shared.json")
        #expect(
            (try SettingsFile.read(at: target)["statusLine"] as? [String: Any])?["command"]
                as? String == "user")
        #expect(
            try Data(contentsOf: root.appendingPathComponent("keep.json")) == Data("keep.json".utf8)
        )
        for name in [
            "statusline.json", ".sl-123", "sessions/old.json", "sessions/claude/session.json",
            "sessions/claude/.tmp.123",
        ] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }

    @Test func linkedCapturedRootFailsClosed() throws {
        let fixture = try Fixture()
        let outside = fixture.home.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("statusline.json")
        try Data("keep".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent(".claude-meter"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try fixture.run() }
        #expect(!fixture.complete)
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
    }
}
