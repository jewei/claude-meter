import Foundation
import MeterPlatform

/// One JSON-RPC conversation with a running `codex app-server`, one compact JSON object per
/// line in each direction.
///
/// The sequence is fixed: `initialize`, the `initialized` notification, `account/read` with
/// `refreshToken: true` (Codex renews and stores its own tokens), then
/// `account/rateLimits/read`. Each step has its own time limit. The caller stops the process.
struct CodexAppServerSession {
    let process: LineProcess
    let stepLimit: Duration

    init(_ process: LineProcess, stepLimit: Duration) {
        self.process = process
        self.stepLimit = stepLimit
    }

    func run() async throws -> CodexRecoveryReply {
        _ = try await call("initialize", id: 1, params: InitializeParams())
        try send(Message(id: nil, method: "initialized", params: NoParams()))
        let account: JSONValue?
        do {
            account = try await call("account/read", id: 2, params: AccountReadParams())
        } catch CodexError.appServerFailed {
            // Codex answered with an error. Account details are optional; the rate limits
            // still say whether the login works.
            account = nil
        }
        // API-key auth has no subscription quota, and no account has no login.
        if CodexAppServerResult.authMode(account: account) == .apiKey
            || CodexAppServerResult.reportsNoAccount(account)
        {
            return CodexRecoveryReply(account: account, rateLimits: nil)
        }
        try Task.checkCancellation()
        let rateLimits = try await call("account/rateLimits/read", id: 3, params: NoParams())
        return CodexRecoveryReply(account: account, rateLimits: rateLimits)
    }

    /// Sends one request and waits at most ``stepLimit`` for its response. A timeout names
    /// this step, even when the process is still running.
    private func call(
        _ method: String, id: Int, params: some Encodable & Sendable
    ) async throws -> JSONValue? {
        try send(Message(id: id, method: method, params: params))
        do {
            return try await withDeadline(stepLimit) { [process] in
                try await Self.response(to: id, from: process)
            }
        } catch is TimeoutError {
            throw CodexError.appServerTimedOut(step: method)
        }
    }

    private func send(_ message: Message<some Encodable & Sendable>) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = try encoder.encode(message)
        do {
            try process.send(line)
        } catch {
            throw CodexError.appServerStopped
        }
    }

    /// The `result` of the response with `id`. Skips lines that are not JSON objects, server
    /// notifications, and server requests, which carry a `method`.
    private static func response(to id: Int, from process: LineProcess) async throws
        -> JSONValue?
    {
        do {
            for try await line in process.lines {
                process.didConsume(line)
                guard let message = JSONValue.parse(line)?.objectValue,
                    message["method"] == nil,
                    message["id"]?.doubleValue == Double(id)
                else { continue }
                if let error = message["error"]?.objectValue {
                    throw CodexError.appServerFailed(error["message"]?.text ?? "no details.")
                }
                return message["result"]
            }
        } catch is LineProcess.ProcessError {
            throw CodexError.appServerUnexpected
        }
        try Task.checkCancellation()
        throw CodexError.appServerStopped
    }
}

private struct Message<Params: Encodable & Sendable>: Encodable, Sendable {
    let id: Int?
    let method: String
    let params: Params
}

private struct NoParams: Encodable, Sendable {}

private struct InitializeParams: Encodable, Sendable {
    struct ClientInfo: Encodable, Sendable {
        let name = "claude-meter"
        let version = "1"
    }

    let clientInfo = ClientInfo()
}

private struct AccountReadParams: Encodable, Sendable {
    let refreshToken = true
}
