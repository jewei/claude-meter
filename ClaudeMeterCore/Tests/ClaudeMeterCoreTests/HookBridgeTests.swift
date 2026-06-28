import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("HookBridge")
struct HookBridgeTests {

    // MARK: - Helpers

    /// Fresh temp config dir; returns its `settings.json` URL.
    private func makeConfigDir() throws -> (dir: URL, settings: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("settings.json"))
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }

    private func readSettings(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Command strings of every hook entry under `event`.
    private func commands(_ settings: [String: Any], event: String) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { group -> [String] in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    // MARK: - Tests

    @Test func installsManagedEventsAndPreservesUserHooks() throws {
        let (dir, settings) = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // User already has an unrelated hook and their own Stop hook.
        try writeJSON(
            [
                "hooks": [
                    "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "echo audit"]]]],
                    "Stop": [["hooks": [["type": "command", "command": "echo my-stop"]]]],
                ]
            ], to: settings)

        try HookBridge.install(configDirs: [dir], events: ["Stop", "Notification"])
        let out = try readSettings(settings)

        // User's unrelated hook untouched.
        #expect(commands(out, event: "PreToolUse") == ["echo audit"])
        // Our Stop entry added alongside the user's own.
        #expect(commands(out, event: "Stop").contains("echo my-stop"))
        #expect(commands(out, event: "Stop").contains(HookBridge.hookSnippet))
        // Notification managed entry present.
        #expect(commands(out, event: "Notification") == [HookBridge.hookSnippet])
    }

    @Test func installIsIdempotent() throws {
        let (dir, settings) = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeJSON([:], to: settings)

        try HookBridge.install(configDirs: [dir], events: ["Stop", "Notification"])
        let first = try Data(contentsOf: settings)
        try HookBridge.install(configDirs: [dir], events: ["Stop", "Notification"])
        let second = try Data(contentsOf: settings)
        // No churn on the per-poll re-install.
        #expect(first == second)
    }

    @Test func togglingOffAnEventRemovesOnlyThatEntry() throws {
        let (dir, settings) = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeJSON([:], to: settings)

        try HookBridge.install(configDirs: [dir], events: ["Stop", "Notification"])
        try HookBridge.install(configDirs: [dir], events: ["Stop"])
        let out = try readSettings(settings)

        #expect(commands(out, event: "Stop") == [HookBridge.hookSnippet])
        // Notification entry gone (and its now-empty key removed).
        let hooks = out["hooks"] as? [String: Any] ?? [:]
        #expect(hooks["Notification"] == nil)
    }

    @Test func uninstallRemovesOursButKeepsUserHooks() throws {
        let (dir, settings) = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeJSON(
            ["hooks": ["Stop": [["hooks": [["type": "command", "command": "echo my-stop"]]]]]],
            to: settings)

        try HookBridge.install(configDirs: [dir], events: ["Stop", "Notification"])
        try HookBridge.uninstall(configDirs: [dir])
        let out = try readSettings(settings)

        // Our entries gone, user's Stop hook intact.
        #expect(commands(out, event: "Stop") == ["echo my-stop"])
        let hooks = out["hooks"] as? [String: Any] ?? [:]
        #expect(hooks["Notification"] == nil)
    }

    @Test func uninstallDropsHooksKeyWhenOnlyOursRemained() throws {
        let (dir, settings) = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeJSON(["theme": "dark"], to: settings)

        try HookBridge.install(configDirs: [dir], events: ["Stop", "Notification"])
        try HookBridge.uninstall(configDirs: [dir])
        let out = try readSettings(settings)

        #expect(out["hooks"] == nil)
        #expect(out["theme"] as? String == "dark")  // unrelated settings preserved
    }

    @Test func invalidSettingsJSONThrows() throws {
        let (dir, settings) = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{ not json".data(using: .utf8)!.write(to: settings)
        #expect(throws: (any Error).self) {
            try HookBridge.install(configDirs: [dir], events: ["Stop"])
        }
    }
}
