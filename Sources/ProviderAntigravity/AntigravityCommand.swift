import Dispatch
import Foundation
import MeterDomain
import MeterPlatform

/// Finds and invokes the `agy` CLI to read Antigravity quota.
protocol AntigravityCLI: Sendable {
    var usesCustomPath: Bool { get }
    func locate() async throws -> AntigravityExecutable.Command
    func fetchUsage(using command: AntigravityExecutable.Command) async throws -> Data
}

/// Runs `agy -p /usage --output-format json --print-timeout 30s` in a private temporary folder.
///
/// The child's standard input is closed immediately, and stderr is watched alongside stdout:
/// when Antigravity is signed out, `agy` prints `"Authentication required"` to stderr and waits
/// for OAuth login. Watching stderr detects that immediately and stops the child instead of
/// waiting out the 30 s deadline.
struct LiveAntigravityCLI: AntigravityCLI {
    static let searchDeadline: Duration = .seconds(5)
    static let commandDeadline: Duration = .seconds(30)
    static let maxOutputBytes = 1024 * 1024

    let environment: [String: String]
    let userHome: URL
    let installFolders: [URL]
    let commandDeadline: Duration

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        installFolders: [URL]? = nil,
        commandDeadline: Duration = LiveAntigravityCLI.commandDeadline
    ) {
        self.environment = environment
        self.userHome = userHome
        self.installFolders =
            installFolders ?? AntigravityExecutable.installFolders(userHome: userHome)
        self.commandDeadline = commandDeadline
    }

    var usesCustomPath: Bool {
        environment["ANTIGRAVITY_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func locate() async throws -> AntigravityExecutable.Command {
        try await AntigravityExecutable.locate(
            environment: environment, installFolders: installFolders, timeout: Self.searchDeadline)
    }

    func fetchUsage(using command: AntigravityExecutable.Command) async throws -> Data {
        let workingDirectory = try await makeWorkingDirectory()
        defer { Self.removeWorkingDirectory(workingDirectory) }

        let childEnvironment = AntigravityEnvironment.child(
            environment, command: command, installFolders: installFolders)
        let process = LineProcess(
            executable: command.url,
            arguments: ["-p", "/usage", "--output-format", "json", "--print-timeout", "30s"],
            environment: childEnvironment,
            currentDirectory: workingDirectory,
            maxLineBytes: Self.maxOutputBytes,
            maxBacklogBytes: Self.maxOutputBytes)

        do {
            try process.start()
        } catch {
            throw AntigravityFailure.launchFailed(
                detail: Redactor.redact(error.localizedDescription))
        }
        process.closeInput()

        do {
            let line = try await withDeadline(commandDeadline) {
                try await Self.readResponse(from: process)
            }
            await process.stop()
            return line
        } catch is CancellationError {
            await process.stop()
            throw CancellationError()
        } catch is TimeoutError {
            await process.stop()
            throw AntigravityFailure.timedOut
        } catch let failure as AntigravityFailure {
            await process.stop()
            throw Self.enrich(
                failure, fullErrorTail: process.errorOutputTail,
                lastErrorLine: process.lastErrorLine)
        } catch {
            await process.stop()
            throw AntigravityFailure.commandFailed(
                detail: process.lastErrorLine ?? Redactor.redact(error.localizedDescription))
        }
    }

    /// Races stdout for the first JSON object line against stderr for an interactive sign-in
    /// prompt. An EOF on stdout without a JSON object returns nil instead of throwing so the
    /// stderr task can finish draining any multi-line sign-in message before reporting failure.
    private static func readResponse(from process: LineProcess) async throws -> Data {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                do {
                    for try await line in process.lines {
                        process.didConsume(line)
                        guard Self.startsWithJSONObject(line),
                            JSONValue.parse(line)?.objectValue != nil
                        else { continue }
                        return line
                    }
                } catch is LineProcess.ProcessError {
                    throw AntigravityFailure.unexpectedResponse(
                        detail: "Antigravity CLI output exceeded the size limit.")
                }
                try Task.checkCancellation()
                return nil
            }
            group.addTask {
                let overlapLimit = max(0, AntigravityUsageResponse.maxSignedOutMarkerBytes - 1)
                var overlap = ""
                for await chunk in process.stderr {
                    let text = String(decoding: chunk, as: UTF8.self).lowercased()
                    let window = overlap + text
                    if AntigravityUsageResponse.indicatesSignedOut(window) {
                        throw AntigravityFailure.signedOut
                    }
                    overlap = overlapLimit > 0 ? String(window.suffix(overlapLimit)) : ""
                }
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let data = result { return data }
            }
            throw AntigravityFailure.commandFailed(detail: nil)
        }
    }

    /// Cheap pre-filter so non-JSON banner lines skip JSON decoding.
    private static func startsWithJSONObject(_ line: Data) -> Bool {
        for byte in line {
            switch byte {
            case 0x20, 0x09, 0x0D: continue
            case 0x7B: return true
            default: return false
            }
        }
        return false
    }

    private static func enrich(
        _ failure: AntigravityFailure, fullErrorTail: String?, lastErrorLine: String?
    ) -> AntigravityFailure {
        if case .commandFailed(nil) = failure {
            if AntigravityUsageResponse.indicatesSignedOut(fullErrorTail)
                || AntigravityUsageResponse.indicatesSignedOut(lastErrorLine)
            {
                return .signedOut
            }
            return .commandFailed(detail: lastErrorLine)
        }
        return failure
    }

    private func makeWorkingDirectory() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "claudemeter-antigravity-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try await BlockingIO.run(timeout: Self.searchDeadline) { _ in
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            return directory
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AntigravityFailure.launchFailed(
                detail: Redactor.redact(error.localizedDescription))
        }
    }

    /// Removes the temporary working directory off the cooperative thread pool.
    private static func removeWorkingDirectory(_ directory: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
