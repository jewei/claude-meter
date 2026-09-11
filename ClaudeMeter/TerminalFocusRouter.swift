import AppKit
import ClaudeMeterCore
import ClaudeMeterProviders
import UserNotifications

/// Installs the notification delegate early enough for macOS to deliver click
/// responses even though Claude Meter has no Dock icon.
final class ClaudeMeterAppDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // Restore the user's log-file choice before any subsystem can log.
        if UserDefaults.standard.bool(forKey: AppGroupConfig.fileLoggingEnabledKey) {
            MeterLog.setFileLoggingEnabled(true)
        }
    }

    /// Ends resident provider subprocesses before the app exits.
    ///
    /// A child outlives its parent on macOS, and closing the pipe only ends a
    /// child that exits on stdin EOF. Ask explicitly, and bound the wait so a
    /// wedged child cannot hold up quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            try? await Timeout.run(seconds: 2) { await CodexSubprocesses.shutdownAll() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
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
    private static let herdrSocketKey = "herdrSocketPath"
    private static let herdrPaneKey = "herdrPaneID"
    private static let herdrCWDKey = "herdrStartupCWD"

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
        if let herdr = route.herdr {
            info[Self.herdrSocketKey] = herdr.socketPath
            info[Self.herdrPaneKey] = herdr.paneID
            if let cwd = herdr.startupCWD { info[Self.herdrCWDKey] = cwd }
        }
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

        let herdr: TerminalRoute.Herdr?
        if let socket = userInfo[Self.herdrSocketKey] as? String,
            let pane = userInfo[Self.herdrPaneKey] as? String
        {
            herdr = TerminalRoute.Herdr(
                socketPath: socket, paneID: pane, startupCWD: userInfo[Self.herdrCWDKey] as? String)
        } else {
            herdr = nil
        }
        self.route = TerminalRoute(
            client: client,
            tty: userInfo[Self.ttyKey] as? String,
            identifier: userInfo[Self.identifierKey] as? String,
            herdr: herdr)
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
        // Transfer activation before exact selection, which may fail or only
        // change focus inside a terminal or Herdr. macOS 14 uses cooperative
        // activation; activating all windows does not grant activation priority.
        NSApp.yieldActivation(to: running)
        if !running.activate(from: .current, options: []) {
            MeterLog.logger(.notification).warning("Terminal activation request was refused")
        }
        guard target.route.client != .warp || target.route.herdr != nil else { return }

        let wezTermExecutable =
            target.route.client == .wezTerm
            ? wezTermCLI(beside: running.executableURL) : nil
        Task.detached(priority: .userInitiated) {
            if !focusPrecisely(target, wezTermExecutable: wezTermExecutable) {
                MeterLog.logger(.notification).warning("Notification target focus failed")
            }
        }
    }

    private static func runningApplication(for client: TerminalRoute.Client)
        -> NSRunningApplication?
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

    struct Command: Sendable, Equatable {
        let executable: String
        let arguments: [String]
        var environment: [String: String] = [:]
    }

    /// The same command path serves notification clicks and isolated tests.
    nonisolated static func focusPrecisely(
        _ target: AttentionNotificationRoute, wezTermExecutable: String? = nil,
        herdrExecutable: String? = nil, execute: (Command) -> Bool = { run($0) }
    ) -> Bool {
        var innerFocused = true
        if let herdr = target.route.herdr {
            if let executable = herdrExecutable ?? fallbackHerdrCLI() {
                innerFocused = execute(
                    Command(
                        executable: executable, arguments: ["agent", "focus", herdr.paneID],
                        environment: ["HERDR_SOCKET_PATH": herdr.socketPath]))
            } else {
                innerFocused = false
            }
        }

        let outerFocused: Bool
        switch target.route.client {
        case .ghostty:
            // Herdr's pane cwd belongs to its inner PTY. Ghostty still reports
            // the folder from which the outer Herdr client started.
            let cwd = if let herdr = target.route.herdr { herdr.startupCWD } else { target.cwd }
            guard let cwd else { return false }
            outerFocused = execute(appleScriptCommand(ghosttyScript(cwd: cwd)))
        case .terminal:
            guard target.route.herdr == nil else { return innerFocused }
            guard let tty = target.route.deviceTTY else { return false }
            outerFocused = execute(appleScriptCommand(terminalScript(tty: tty)))
        case .iTerm2:
            guard target.route.herdr == nil else { return innerFocused }
            guard let tty = target.route.deviceTTY else { return false }
            outerFocused = execute(appleScriptCommand(iTermScript(tty: tty)))
        case .wezTerm:
            guard let pane = target.route.identifier,
                let executable = wezTermExecutable ?? fallbackWezTermCLI()
            else { return false }
            outerFocused = execute(
                Command(
                    executable: executable, arguments: ["cli", "activate-pane", "--pane-id", pane]))
        case .warp:
            return innerFocused
        }
        return innerFocused && outerFocused
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

    private nonisolated static func fallbackHerdrCLI() -> String? {
        let candidates = [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".local/bin/herdr"
            ).path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func appleScriptCommand(_ source: String) -> Command {
        Command(executable: "/usr/bin/osascript", arguments: ["-e", source])
    }

    /// Runs a helper with a bounded wait. A hung osascript (pending Automation
    /// consent dialog, busy AppleEvent target) must not pin a cooperative-pool
    /// thread indefinitely — SIGTERM after `timeout`, SIGKILL if it lingers
    /// (same escalation as `CursorTokenStore`'s sqlite3 runner).
    nonisolated static func run(
        _ command: Command, timeout: TimeInterval = 10
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) {
            _, new in new
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            return false
        }
        return process.terminationStatus == 0
    }

    private nonisolated static func ghosttyScript(cwd: String) -> String {
        // Tolerate a trailing-slash mismatch between the hook's POSIX cwd and
        // Ghostty's reported working directory (both directions).
        let normalized = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let directory = appleScriptLiteral(normalized)
        // `is running` never launches; `tell` without it would relaunch a terminal
        // that quit between the click-time check and this script running.
        return """
            if application "Ghostty" is running then
                tell application "Ghostty"
                    set targetDirectory to \(directory)
                    repeat with targetWindow in windows
                        repeat with targetTab in tabs of targetWindow
                            repeat with targetTerminal in terminals of targetTab
                                set wd to working directory of targetTerminal
                                if wd is targetDirectory or wd is (targetDirectory & "/") then
                                    focus targetTerminal
                                    activate
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                    error "No matching Ghostty terminal" number 1
                end tell
            end if
            """
    }

    private nonisolated static func terminalScript(tty: String) -> String {
        let targetTTY = appleScriptLiteral(tty)
        return """
            if application "Terminal" is running then
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
            end if
            """
    }

    private nonisolated static func iTermScript(tty: String) -> String {
        let targetTTY = appleScriptLiteral(tty)
        return """
            if application "iTerm2" is running then
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
            end if
            """
    }

    private nonisolated static func appleScriptLiteral(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
