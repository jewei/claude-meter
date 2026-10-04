import Foundation
import MeterPlatform

/// The live ``CodexRecovery``: one `codex app-server` child per call, with no reuse.
///
/// Every path out of ``recover(_:environment:)`` stops the child and waits until it is reaped,
/// including timeouts, failures, and cancellation.
struct CodexAppServer: CodexRecovery {
    /// A read-only sandbox, and an approval policy that never asks, keep the child
    /// non-interactive.
    static let arguments = ["-s", "read-only", "-a", "never", "app-server"]

    /// The user's home folder, for the install folders that `PATH` does not list.
    let userHome: URL
    /// The limit for each JSON-RPC step and for finding the executable.
    let stepLimit: Duration

    func recover(
        _ home: CodexHome, environment: [String: String]
    ) async throws -> CodexRecoveryReply {
        let executable = try await CodexExecutable.locate(
            environment: environment, userHome: userHome, timeout: stepLimit)
        let process = LineProcess(
            executable: executable, arguments: Self.arguments,
            environment: CodexEnvironment.scrubbed(environment))
        do {
            try process.start()
        } catch {
            throw CodexError.appServerLaunchFailed
        }
        // One exit for every path, so the child is always stopped and reaped.
        let outcome: Result<CodexRecoveryReply, any Error>
        do {
            outcome = .success(try await CodexAppServerSession(process, stepLimit: stepLimit).run())
        } catch {
            outcome = .failure(error)
        }
        await process.stop()
        try Task.checkCancellation()
        return try outcome.get()
    }
}
