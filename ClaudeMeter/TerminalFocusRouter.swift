import AppKit
import ClaudeMeterCore
import UserNotifications

/// Installs the notification delegate early enough for macOS to deliver click
/// responses even though Claude Meter has no Dock icon.
final class ClaudeMeterAppDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let target = AttentionNotificationRoute(
                userInfo: response.notification.request.content.userInfo)
        {
            Task { @MainActor in TerminalFocusRouter.focus(target) }
        }
        completionHandler()
    }
}

/// Versioned payload placed on attention notifications. Quota and update
/// notifications intentionally carry no terminal route.
struct AttentionNotificationRoute: Sendable {
    private static let versionKey = "claudeMeterAttentionRouteVersion"
    private static let clientKey = "terminalClient"
    private static let ttyKey = "terminalTTY"
    private static let identifierKey = "terminalIdentifier"
    private static let cwdKey = "terminalCWD"

    let route: TerminalRoute
    let cwd: String?

    var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            Self.versionKey: 1,
            Self.clientKey: route.client.rawValue,
        ]
        if let tty = route.tty { info[Self.ttyKey] = tty }
        if let identifier = route.identifier { info[Self.identifierKey] = identifier }
        if let cwd, !cwd.isEmpty { info[Self.cwdKey] = cwd }
        return info
    }

    init(route: TerminalRoute, cwd: String?) {
        self.route = route
        self.cwd = cwd
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard (userInfo[Self.versionKey] as? NSNumber)?.intValue == 1,
            let rawClient = userInfo[Self.clientKey] as? String,
            let client = TerminalRoute.Client(rawValue: rawClient)
        else { return nil }

        let program: String
        switch client {
        case .ghostty: program = "ghostty"
        case .terminal: program = "Apple_Terminal"
        case .iTerm2: program = "iTerm.app"
        case .wezTerm: program = "WezTerm"
        case .warp: program = "WarpTerminal"
        }
        guard
            let route = TerminalRoute(
                termProgram: program,
                tty: userInfo[Self.ttyKey] as? String,
                identifier: userInfo[Self.identifierKey] as? String)
        else { return nil }
        self.route = route
        self.cwd = userInfo[Self.cwdKey] as? String
    }
}

@MainActor
enum TerminalFocusRouter {
    private static let bundleIdentifiers: [TerminalRoute.Client: [String]] = [
        .ghostty: ["com.mitchellh.ghostty"],
        .terminal: ["com.apple.Terminal"],
        .iTerm2: ["com.googlecode.iterm2", "com.googlecode.iterm2.beta"],
        .wezTerm: ["com.github.wez.wezterm"],
        .warp: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "dev.warp.Warp"],
    ]

    /// Focuses an already-running terminal. A stale notification never launches a
    /// terminal or creates a new window; it simply becomes a no-op.
    static func focus(_ target: AttentionNotificationRoute) {
        guard let running = runningApplication(for: target.route.client) else { return }
        if target.route.client == .warp {
            running.activate(options: [.activateAllWindows])
            return
        }

        let wezTermExecutable = target.route.client == .wezTerm
            ? wezTermCLI(beside: running.executableURL) : nil
        Task {
            let focused = await Task.detached(priority: .userInitiated) {
                focusPrecisely(target, wezTermExecutable: wezTermExecutable)
            }.value
            guard !focused, let fallback = runningApplication(for: target.route.client) else {
                return
            }
            fallback.activate(options: [.activateAllWindows])
        }
    }

    private static func runningApplication(for client: TerminalRoute.Client) -> NSRunningApplication?
    {
        for bundleIdentifier in bundleIdentifiers[client] ?? [] {
            if let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first {
                return app
            }
        }
        return nil
    }

    private nonisolated static func focusPrecisely(
        _ target: AttentionNotificationRoute, wezTermExecutable: String?
    ) -> Bool {
        switch target.route.client {
        case .ghostty:
            guard let cwd = target.cwd else { return false }
            return runAppleScript(ghosttyScript(cwd: cwd))
        case .terminal:
            guard let tty = target.route.deviceTTY else { return false }
            return runAppleScript(terminalScript(tty: tty))
        case .iTerm2:
            guard let tty = target.route.deviceTTY else { return false }
            return runAppleScript(iTermScript(tty: tty))
        case .wezTerm:
            guard let pane = target.route.identifier,
                let executable = wezTermExecutable ?? fallbackWezTermCLI()
            else { return false }
            return run(executable, arguments: ["cli", "activate-pane", "--pane-id", pane])
        case .warp:
            return false
        }
    }

    private static func wezTermCLI(beside executableURL: URL?) -> String? {
        guard let executableURL else { return nil }
        let candidate = executableURL.deletingLastPathComponent().appendingPathComponent("wezterm")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate.path : nil
    }

    private nonisolated static func fallbackWezTermCLI() -> String? {
        let candidates = [
            "/Applications/WezTerm.app/Contents/MacOS/wezterm",
            "/opt/homebrew/bin/wezterm",
            "/usr/local/bin/wezterm",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func runAppleScript(_ source: String) -> Bool {
        run("/usr/bin/osascript", arguments: ["-e", source])
    }

    private nonisolated static func run(_ executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private nonisolated static func ghosttyScript(cwd: String) -> String {
        let directory = appleScriptLiteral(cwd)
        return """
            tell application "Ghostty"
                set targetDirectory to \(directory)
                repeat with targetWindow in windows
                    repeat with targetTab in tabs of targetWindow
                        repeat with targetTerminal in terminals of targetTab
                            if working directory of targetTerminal is targetDirectory then
                                focus targetTerminal
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
                error "No matching Ghostty terminal" number 1
            end tell
            """
    }

    private nonisolated static func terminalScript(tty: String) -> String {
        let targetTTY = appleScriptLiteral(tty)
        return """
            tell application "Terminal"
                set wantedTTY to \(targetTTY)
                repeat with targetWindow in windows
                    repeat with targetTab in tabs of targetWindow
                        if tty of targetTab is wantedTTY then
                            set selected tab of targetWindow to targetTab
                            set frontmost of targetWindow to true
                            activate
                            return
                        end if
                    end repeat
                end repeat
                error "No matching Terminal tab" number 1
            end tell
            """
    }

    private nonisolated static func iTermScript(tty: String) -> String {
        let targetTTY = appleScriptLiteral(tty)
        return """
            tell application "iTerm2"
                set wantedTTY to \(targetTTY)
                repeat with targetWindow in windows
                    repeat with targetTab in tabs of targetWindow
                        repeat with targetSession in sessions of targetTab
                            if tty of targetSession is wantedTTY then
                                tell targetSession to select
                                tell targetTab to select
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
                error "No matching iTerm2 session" number 1
            end tell
            """
    }

    private nonisolated static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
