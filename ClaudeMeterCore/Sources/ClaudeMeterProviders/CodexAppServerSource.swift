import ClaudeMeterCore
import Darwin
import Foundation

public enum CodexCLILocator {
    public static func resolve(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let override = env["CODEX_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty,
            fileManager.isExecutableFile(atPath: override)
        {
            return override
        }
        if let pathValue = env["PATH"] {
            for dir in pathValue.split(separator: ":").map(String.init) {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent("codex").path
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        for candidate in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"] {
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

public struct CodexAppServerAccountResponse: Decodable, Sendable {
    public let account: CodexAppServerAccount

    private enum CodingKeys: String, CodingKey {
        case account
    }

    private enum AccountKeys: String, CodingKey {
        case type
        case email
        case planType
        case planTypeSnake = "plan_type"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accountContainer = try container.nestedContainer(
            keyedBy: AccountKeys.self, forKey: .account)
        let type = try? accountContainer.decodeIfPresent(String.self, forKey: .type)
        let email = try? accountContainer.decodeIfPresent(String.self, forKey: .email)
        let plan =
            (try? accountContainer.decodeIfPresent(String.self, forKey: .planType))
            ?? (try? accountContainer.decodeIfPresent(String.self, forKey: .planTypeSnake))
        self.account = CodexAppServerAccount(
            email: email,
            plan: plan,
            authMode: Self.authMode(from: type))
    }

    private static func authMode(from raw: String?) -> CodexAccountAuthMode {
        switch raw?.lowercased() {
        case "chatgpt", "chat_gpt":
            return .chatGPT
        case "api", "api_key", "apikey", "openai_api_key":
            return .apiKey
        default:
            return .unknown
        }
    }
}

public final class CodexAppServerSource: CodexUsageSourceFetching, @unchecked Sendable {
    private let env: [String: String]
    private let startupTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let resolver: @Sendable ([String: String]) -> String?

    public init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        startupTimeout: TimeInterval = 5,
        requestTimeout: TimeInterval = 5,
        resolver: @escaping @Sendable ([String: String]) -> String? = {
            CodexCLILocator.resolve(env: $0)
        }
    ) {
        self.env = env
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
        self.resolver = resolver
    }

    public func fetchUsage(now: Date = Date()) async throws -> CodexUsage {
        try Task.checkCancellation()
        guard let executable = resolver(env) else { throw CodexUsageError.cliNotFound }
        try Task.checkCancellation()
        let client = try CodexAppServerClient(
            executable: executable,
            env: env,
            startupTimeout: startupTimeout,
            requestTimeout: requestTimeout)
        do {
            let usage = try await fetchUsage(client: client, now: now)
            await client.shutdown()
            return usage
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private func fetchUsage(client: CodexAppServerClient, now: Date) async throws -> CodexUsage {
        try Task.checkCancellation()
        try await client.initialize()
        try Task.checkCancellation()
        let account: CodexAppServerAccount?
        do {
            account = try await client.fetchAccount().account
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            account = nil
        }
        // Account metadata is optional, but cancellation is not. Do not start a
        // rate-limit request after the caller cancels an account request.
        try Task.checkCancellation()
        let limits = try await client.fetchRateLimits()
        try Task.checkCancellation()
        return try limits.usage(account: account, now: now, source: .appServer)
    }
}

final class CodexAppServerClient: @unchecked Sendable {
    private static let maxBufferedMessages = 16
    private static let terminationGraceSeconds: TimeInterval = 0.25
    // App Server only reads account and quota data. `never` keeps the subprocess
    // noninteractive and is accepted by current Codex CLIs; `untrusted` was removed.
    static let processArguments = ["-s", "read-only", "-a", "never", "app-server"]

    private struct JSONMessage: @unchecked Sendable {
        let value: [String: Any]
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation
    /// Guards `nextID`. The class is `@unchecked Sendable` and `request` is async,
    /// so nothing stops two overlapping calls; sharing an id would let the response
    /// matcher hand one caller the other's payload.
    private let idLock = NSLock()
    private var nextID = 1
    private let shutdownLock = NSLock()
    private var shutdownStarted = false
    private var shutdownFinished = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private let shutdownQueue = DispatchQueue(
        label: "com.jewei.claudemeter.codex-shutdown", qos: .utility)
    private let requestGate = CodexRPCRequestGate()
    private let startupTimeout: TimeInterval
    private let requestTimeout: TimeInterval

    init(
        executable: String,
        env: [String: String],
        startupTimeout: TimeInterval,
        requestTimeout: TimeInterval
    ) throws {
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
        var continuation: AsyncStream<Data>.Continuation!
        self.stdoutLineStream = AsyncStream(
            bufferingPolicy: .bufferingNewest(
                Self.maxBufferedMessages
            )
        ) { continuation = $0 }
        self.stdoutLineContinuation = continuation

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.processArguments
        // Scrub auth-override vars (CODEX_API_KEY, OPENAI_BASE_URL, …) so an env
        // inherited from a terminal launch can't point the read at a different
        // account/provider than the local login.
        process.environment = AuthEnv.scrubbed(env)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        installReaders()
    }

    func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: ["clientInfo": ["name": "claude-meter", "version": "1"]],
            timeout: startupTimeout)
        try Task.checkCancellation()
        try sendNotification(method: "initialized")
    }

    func fetchAccount() async throws -> CodexAppServerAccountResponse {
        try await decodeResult(from: request(method: "account/read", timeout: requestTimeout))
    }

    func fetchRateLimits() async throws -> CodexAppServerRateLimitsResponse {
        try await decodeResult(
            from: request(method: "account/rateLimits/read", timeout: requestTimeout))
    }

    func shutdown() async {
        await withCheckedContinuation { continuation in
            shutdownLock.lock()
            if shutdownFinished {
                shutdownLock.unlock()
                continuation.resume()
                return
            }
            shutdownWaiters.append(continuation)
            guard !shutdownStarted else {
                shutdownLock.unlock()
                return
            }
            shutdownStarted = true
            shutdownLock.unlock()

            // Foundation's process wait and TERM grace period must not block
            // Swift's cooperative executor. Every caller awaits the same cleanup,
            // including callers that are already cancelled.
            shutdownQueue.async {
                self.stopProcess()
                self.shutdownLock.lock()
                self.shutdownFinished = true
                let waiters = self.shutdownWaiters
                self.shutdownWaiters.removeAll()
                self.shutdownLock.unlock()
                for waiter in waiters { waiter.resume() }
            }
        }
    }

    private func stopProcess() {
        try? stdinPipe.fileHandleForWriting.close()

        if process.isRunning {
            process.terminate()
            let deadline =
                ProcessInfo.processInfo.systemUptime + Self.terminationGraceSeconds
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        // SIGKILL cannot be ignored. Wait here so the terminated child is reaped
        // instead of remaining as a zombie for the lifetime of the app.
        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutLineContinuation.finish()
    }

    private func installReaders() {
        let continuation = stdoutLineContinuation
        let buffer = BoundedProcessLineBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            let result = buffer.appendAndDrainLines(data)
            guard !result.exceededLimit else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in result.lines { continuation.yield(line) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
    }

    private func request(
        method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        await requestGate.acquire()
        do {
            let value = try await performRequest(method: method, params: params, timeout: timeout)
            await requestGate.release()
            return value
        } catch {
            await requestGate.release()
            throw error
        }
    }

    /// One stdout stream cannot safely be consumed by concurrent request loops: a
    /// loop would discard the other request's response. Serialize the complete
    /// send/read exchange while still allowing callers to invoke this client safely.
    private func performRequest(
        method: String,
        params: [String: Any],
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        let id = claimRequestID()
        try sendPayload(["id": id, "method": method, "params": params])
        let wrapped = try await withTimeout(seconds: timeout, method: method) {
            while true {
                let message = try await self.readNextMessage()
                if message["id"] == nil { continue }
                guard self.jsonID(message["id"]) == id else { continue }
                if let error = message["error"] as? [String: Any],
                    let text = error["message"] as? String
                {
                    throw CodexUsageError.rpcFailed(text)
                }
                return JSONMessage(value: message)
            }
        }
        return wrapped.value
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        method: String,
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = CodexTimeoutRace()
        return try await withThrowingTaskGroup(of: CodexTimeoutOutcome<T>.self) { group in
            group.addTask {
                do {
                    let value = try await body()
                    try Task.checkCancellation()
                    guard race.claim() else { return .lost }
                    return .value(value)
                } catch {
                    guard race.claim() else { return .lost }
                    throw error
                }
            }
            group.addTask { [weak self] in
                try await Task.sleep(for: .seconds(seconds))
                guard race.claim() else { return .lost }
                // Claim the result before shutdown. A response that arrives
                // during the TERM grace period cannot change the winner.
                await self?.shutdown()
                throw CodexUsageError.rpcTimedOut(method)
            }
            while let outcome = try await group.next() {
                guard case .value(let result) = outcome else { continue }
                group.cancelAll()
                return result
            }
            throw CodexUsageError.rpcTimedOut(method)
        }
    }

    private func claimRequestID() -> Int {
        idLock.lock()
        defer { idLock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    private func sendNotification(method: String) throws {
        try sendPayload(["method": method, "params": [:]])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)

        // Use the shutdown lock for the state check and the write. Shutdown can
        // close stdin only before or after a complete framed message.
        shutdownLock.lock()
        defer { shutdownLock.unlock() }
        guard !shutdownStarted else { throw CodexUsageError.invalidRPCResponse }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func readNextMessage() async throws -> [String: Any] {
        for await line in stdoutLineStream {
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                return json
            }
        }
        try Task.checkCancellation()
        throw CodexUsageError.invalidRPCResponse
    }

    private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
        guard let result = message["result"] else { throw CodexUsageError.invalidRPCResponse }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: int
        case let number as NSNumber: number.intValue
        default: nil
        }
    }
}

private final class CodexTimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var hasWinner = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasWinner else { return false }
        hasWinner = true
        return true
    }
}

private enum CodexTimeoutOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case lost
}

private actor CodexRPCRequestGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
