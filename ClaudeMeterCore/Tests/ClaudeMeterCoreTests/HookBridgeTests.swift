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

    @Test func preservesUserCommandColocatedInOurGroup() throws {
        let (dir, settings) = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A Stop group that mixes the user's own command with ours (e.g. a manual merge).
        try writeJSON(
            [
                "hooks": [
                    "Stop": [[
                        "hooks": [
                            ["type": "command", "command": "echo mine"],
                            ["type": "command", "command": HookBridge.hookSnippet],
                        ]
                    ]]
                ]
            ], to: settings)

        try HookBridge.install(configDirs: [dir], events: ["Stop"])
        let out = try readSettings(settings)
        // The user's command survives; ours is present exactly once.
        #expect(commands(out, event: "Stop").contains("echo mine"))
        #expect(commands(out, event: "Stop").filter { $0 == HookBridge.hookSnippet }.count == 1)

        // And toggling Stop off strips only ours, keeping the user's command.
        try HookBridge.install(configDirs: [dir], events: [])
        let off = try readSettings(settings)
        #expect(commands(off, event: "Stop") == ["echo mine"])
    }

    @Test func leavesMalformedHooksShapeUntouched() throws {
        let (dir, settings) = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // `hooks` present but not an object → must not be clobbered.
        try writeJSON(["hooks": ["not", "an", "object"]], to: settings)
        try HookBridge.install(configDirs: [dir], events: ["Stop", "Notification"])
        let out = try readSettings(settings)
        #expect(out["hooks"] as? [String] == ["not", "an", "object"])
    }

    @Test func leavesMalformedEventArrayUntouched() throws {
        let (dir, settings) = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // hooks.Stop is an array with a non-object element → leave it alone.
        try writeJSON(["hooks": ["Stop": ["bogus"]]], to: settings)
        try HookBridge.install(configDirs: [dir], events: ["Stop"])
        let out = try readSettings(settings)
        let hooks = out["hooks"] as? [String: Any] ?? [:]
        #expect(hooks["Stop"] as? [String] == ["bogus"])
    }

    @Test func migratesLegacySnippet() throws {
        let (dir, settings) = try makeConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = try #require(HookBridge.legacyHookSnippets.first)
        try writeJSON(
            ["hooks": ["Stop": [["hooks": [["type": "command", "command": legacy]]]]]],
            to: settings)

        try HookBridge.install(configDirs: [dir], events: ["Stop"])
        let out = try readSettings(settings)
        // Legacy replaced by current — no duplicate, no leftover legacy.
        #expect(commands(out, event: "Stop") == [HookBridge.hookSnippet])
    }

    @Test func hookMarkerCapturesTerminalRoute() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", HookBridge.hookSnippet]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(".claude-work").path
        environment["TERM_PROGRAM"] = "WezTerm"
        environment["WEZTERM_PANE"] = "42"
        environment.removeValue(forKey: "ITERM_SESSION_ID")
        environment.removeValue(forKey: "TERM_SESSION_ID")
        environment.removeValue(forKey: "WARP_SESSION_ID")
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        try input.fileHandleForWriting.write(
            contentsOf: Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let eventsRoot = home.appendingPathComponent(".claude-meter/events")
        let event = try #require(
            SessionEventStore.drain(
                eventsRoot: eventsRoot, disabledAccountKeys: [], now: Date(), maxAge: 120
            ).first)
        #expect(event.accountKey == "claude-work")
        #expect(event.terminalRoute?.client == .wezTerm)
        #expect(event.terminalRoute?.identifier == "42")
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
