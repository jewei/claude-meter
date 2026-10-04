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

    /// The install folders that `PATH` does not list, for the search and the child's `PATH`.
    let installFolders: [URL]
    /// The limit for finding the executable and for `initialize`.
    let stepLimit: Duration
    /// The limit for each step that reaches the network.
    let networkStepLimit: Duration

    func recover(
        _ home: CodexHome, environment: [String: String]
    ) async throws -> CodexRecoveryReply {
        let command = try await CodexExecutable.locate(
            environment: environment, installFolders: installFolders, timeout: stepLimit)
        let process = LineProcess(
            executable: command.url, arguments: Self.arguments,
            environment: CodexEnvironment.child(
                environment, command: command, installFolders: installFolders))
        do {
            try process.start()
        } catch {
            throw CodexError.appServerLaunchFailed
        }
        // One exit for every path, so the child is always stopped and reaped.
        let outcome: Result<CodexRecoveryReply, any Error>
        do {
            let session = CodexAppServerSession(
                process, stepLimit: stepLimit, networkStepLimit: networkStepLimit)
            outcome = .success(try await session.run())
        } catch {
            outcome = .failure(error)
        }
        await process.stop()
        try Task.checkCancellation()
        return try outcome.get()
    }
}
