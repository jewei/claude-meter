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
        let accountContainer = try container.nestedContainer(keyedBy: AccountKeys.self, forKey: .account)
        let type = try? accountContainer.decodeIfPresent(String.self, forKey: .type)
        let email = try? accountContainer.decodeIfPresent(String.self, forKey: .email)
        let plan = (try? accountContainer.decodeIfPresent(String.self, forKey: .planType))
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
        resolver: @escaping @Sendable ([String: String]) -> String? = { CodexCLILocator.resolve(env: $0) }
    ) {
        self.env = env
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
        self.resolver = resolver
    }

    public func isAvailable() async -> Bool {
        resolver(env) != nil
    }

    public func fetchUsage(now: Date = Date()) async throws -> CodexUsage {
        guard let executable = resolver(env) else { throw CodexUsageError.cliNotFound }
        let client = try CodexAppServerClient(
            executable: executable,
            env: env,
            startupTimeout: startupTimeout,
            requestTimeout: requestTimeout)
        defer { client.shutdown() }
        try await client.initialize()
        let account = try? await client.fetchAccount().account
        let limits = try await client.fetchRateLimits()
        return try limits.usage(account: account, now: now, source: .appServer)
    }
}

final class CodexAppServerClient: @unchecked Sendable {
    private struct JSONMessage: @unchecked Sendable {
        let value: [String: Any]
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation
    private var nextID = 1
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
        self.stdoutLineStream = AsyncStream { continuation = $0 }
        self.stdoutLineContinuation = continuation

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        process.environment = env
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
        try sendNotification(method: "initialized")
    }

    func fetchAccount() async throws -> CodexAppServerAccountResponse {
        try await decodeResult(from: request(method: "account/read", timeout: requestTimeout))
    }

    func fetchRateLimits() async throws -> CodexAppServerRateLimitsResponse {
        try await decodeResult(from: request(method: "account/rateLimits/read", timeout: requestTimeout))
    }

    func shutdown() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? stdinPipe.fileHandleForWriting.close()
    }

    private func installReaders() {
        final class LineBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var buffer = Data()
            func append(_ data: Data) -> [Data] {
                lock.lock()
                defer { lock.unlock() }
                buffer.append(data)
                var lines: [Data] = []
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if !line.isEmpty { lines.append(line) }
                }
                return lines
            }
        }

        let continuation = stdoutLineContinuation
        let buffer = LineBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.append(data) { continuation.yield(line) }
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
        let id = nextID
        nextID += 1
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
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { [weak self] in
                try await Task.sleep(for: .seconds(seconds))
                self?.shutdown()
                throw CodexUsageError.rpcTimedOut(method)
            }
            guard let result = try await group.next() else {
                throw CodexUsageError.rpcTimedOut(method)
            }
            group.cancelAll()
            return result
        }
    }

    private func sendNotification(method: String) throws {
        try sendPayload(["method": method, "params": [:]])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readNextMessage() async throws -> [String: Any] {
        for await line in stdoutLineStream {
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                return json
            }
        }
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
