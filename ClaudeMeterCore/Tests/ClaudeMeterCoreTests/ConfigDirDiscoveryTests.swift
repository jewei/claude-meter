import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("ConfigDirDiscovery")
struct ConfigDirDiscoveryTests {

    // MARK: - accountKey (must match the bridge bash snippet byte-for-byte)

    @Test func accountKeyStripsLeadingDotAndSanitizes() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(
            ConfigDirDiscovery.accountKey(for: home.appendingPathComponent(".claude")) == "claude")
        #expect(
            ConfigDirDiscovery.accountKey(for: home.appendingPathComponent(".claude-it-oneone"))
                == "claude-it-oneone")
        // Only [A-Za-z0-9._-] survive (matches `tr -cd "[:alnum:]._-"`); the rest go.
        #expect(
            ConfigDirDiscovery.accountKey(for: home.appendingPathComponent(".claude work!@#"))
                == "claudework")
    }

    @Test func accountKeyFallsBackToClaudeWhenEmpty() {
        // A basename that sanitizes to empty → "claude" (matches the bash fallback).
        #expect(ConfigDirDiscovery.accountKey(for: URL(fileURLWithPath: "/x/\u{3002}")) == "claude")
    }

    // MARK: - label

    @Test func labelDerivation() {
        #expect(ConfigDirDiscovery.label(forKey: "claude") == "default")
        #expect(ConfigDirDiscovery.label(forKey: "claude-it-oneone") == "it-oneone")
        #expect(ConfigDirDiscovery.label(forKey: "claude-work") == "work")
        // No `claude-` prefix → unchanged.
        #expect(ConfigDirDiscovery.label(forKey: "custom") == "custom")
        // Exactly `claude-` with nothing after → unchanged, not empty.
        #expect(ConfigDirDiscovery.label(forKey: "claude-") == "claude-")
    }

    // MARK: - discover

    /// Builds a throwaway home with the named `.claude*` dirs and returns it.
    private func makeHome(
        _ build: (_ home: URL, _ make: (String, Bool, Bool) throws -> URL) throws -> Void
    ) throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        func make(_ name: String, settings: Bool, projects: Bool) throws -> URL {
            let dir = home.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if settings { try Data("{}".utf8).write(to: dir.appendingPathComponent("settings.json")) }
            if projects {
                try fm.createDirectory(
                    at: dir.appendingPathComponent("projects"), withIntermediateDirectories: true)
            }
            return dir
        }
        try build(home, make)
        return home
    }

    @Test func discoverIncludesQualifyingDirsExcludesEmptyOnes() throws {
        let home = try makeHome { _, make in
            _ = try make(".claude", true, false)  // default
            _ = try make(".claude-work", true, false)  // qualifies (settings.json)
            _ = try make(".claude-proj", false, true)  // qualifies (projects/)
            _ = try make(".claude-empty", false, false)  // excluded (neither)
            _ = try make(".config", true, false)  // not a .claude* dir
        }
        defer { try? FileManager.default.removeItem(at: home) }

        let found = ConfigDirDiscovery.discover(home: home, fileManager: .default)
        #expect(found.first?.id == "claude")  // default listed first
        #expect(Set(found.map(\.id)) == ["claude", "claude-work", "claude-proj"])
    }

    @Test func discoverAlwaysIncludesDefaultEvenIfEmpty() throws {
        let home = try makeHome { _, make in
            _ = try make(".claude", false, false)  // no settings, no projects
        }
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ConfigDirDiscovery.discover(home: home, fileManager: .default).map(\.id) == ["claude"])
    }

    @Test func discoverHonorsDisabledKeysButNeverDropsDefault() throws {
        let home = try makeHome { _, make in
            _ = try make(".claude", true, false)
            _ = try make(".claude-work", true, false)
        }
        defer { try? FileManager.default.removeItem(at: home) }

        // Disabling the default is ignored; disabling a real account drops it.
        let found = ConfigDirDiscovery.discover(
            home: home, fileManager: .default, disabledKeys: ["claude", "claude-work"])
        #expect(found.map(\.id) == ["claude"])
    }

    @Test func discoverIncludesConfiguredCustomDirs() throws {
        let fm = FileManager.default
        let home = try makeHome { _, make in _ = try make(".claude", true, false) }
        let custom = fm.temporaryDirectory.appendingPathComponent(
            "cfg-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: custom, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: home)
            try? fm.removeItem(at: custom)
        }

        let found = ConfigDirDiscovery.discover(
            home: home, fileManager: fm, configuredDirs: [custom.path])
        #expect(
            found.contains { $0.configDir.standardizedFileURL == custom.standardizedFileURL })
    }

    @Test func discoverDedupsConfiguredDuplicateOfScannedDir() throws {
        // The default dir also passed explicitly as a configured dir → one entry.
        let home = try makeHome { _, make in _ = try make(".claude", true, false) }
        defer { try? FileManager.default.removeItem(at: home) }
        let claudePath = home.appendingPathComponent(".claude").path

        let found = ConfigDirDiscovery.discover(
            home: home, fileManager: .default, configuredDirs: [claudePath])
        #expect(found.map(\.id) == ["claude"])
    }
}
