import Foundation

public struct CursorCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let email: String?
    public let membership: String?
}

/// Reads Cursor's locally-stored auth from `state.vscdb` (the editor's
/// VS Code-style key/value store), with a macOS Keychain fallback. Cursor keeps
/// the access/refresh tokens here; we only ever read them.
public enum CursorTokenStore {

    /// macOS path to Cursor's global key/value SQLite store.
    static var stateDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            )
            .path
    }

    private static let sqlite3Path = "/usr/bin/sqlite3"
    private static let securityPath = "/usr/bin/security"
    private static let processTimeoutSeconds: TimeInterval = 10

    private static let stateKeys = [
        "cursorAuth/accessToken",
        "cursorAuth/refreshToken",
        "cursorAuth/cachedEmail",
        "cursorAuth/stripeMembershipType",
    ]

    // MARK: - Detection

    /// Best-effort detection of Cursor credentials. Returns nil when Cursor isn't
    /// installed / signed in.
    public static func detect() -> CursorCredentials? {
        let values = readStateValues(stateKeys)
        var access = values["cursorAuth/accessToken"]
        var refresh = values["cursorAuth/refreshToken"]
        let email = values["cursorAuth/cachedEmail"]
        let membership = values["cursorAuth/stripeMembershipType"]?.lowercased()

        if access?.isEmpty ?? true { access = keychainValue(service: "cursor-access-token") }
        if refresh?.isEmpty ?? true { refresh = keychainValue(service: "cursor-refresh-token") }

        guard let token = access, !token.isEmpty else { return nil }
        return CursorCredentials(
            accessToken: token,
            refreshToken: refresh?.isEmpty == false ? refresh : nil,
            email: email?.isEmpty == false ? email : nil,
            membership: membership?.isEmpty == false ? membership : nil
        )
    }

    /// True when Cursor's state DB exists (filesystem-only; no Keychain/subprocess).
    public static func isStateDBPresent() -> Bool {
        FileManager.default.fileExists(atPath: stateDBPath)
    }

    /// True when Cursor's state DB or Keychain entry exists (used before polling).
    public static func isAvailable() -> Bool {
        isStateDBPresent() || keychainValue(service: "cursor-access-token") != nil
    }

    // MARK: - JWT expiry

    /// The access token is a JWT; returns its `exp` as a `Date` when decodable.
    public static func expiry(of accessToken: String) -> Date? {
        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2,
            let payload = base64URLDecode(String(parts[1])),
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let exp = (object["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// True when the token is missing an expiry, already expired, or expires
    /// within `buffer` seconds (default 5 minutes — matches Cursor's own buffer).
    public static func isExpiringSoon(
        _ accessToken: String, buffer: TimeInterval = 300, now: Date = Date()
    ) -> Bool {
        guard let exp = expiry(of: accessToken) else { return true }
        return exp.timeIntervalSince(now) < buffer
    }

    // MARK: - SQLite read

    static func readStateValues(_ keys: [String]) -> [String: String] {
        guard FileManager.default.fileExists(atPath: stateDBPath), !keys.isEmpty else { return [:] }
        // Keys are fixed constants, so the inline query is injection-safe.
        let quoted = keys.map { "'\($0)'" }.joined(separator: ", ")
        let query = "SELECT key, value FROM ItemTable WHERE key IN (\(quoted));"
        guard let output = run(sqlite3Path, ["-readonly", stateDBPath, query]) else { return [:] }

        var result: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = unquoteStoredValue(parts[1])
            if !value.isEmpty { result[parts[0]] = value }
        }
        return result
    }

    static func readStateValue(_ key: String) -> String? {
        readStateValues([key])[key]
    }

    private static func keychainValue(service: String) -> String? {
        guard let output = run(securityPath, ["find-generic-password", "-s", service, "-w"]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : unquoteStoredValue(trimmed)
    }

    // MARK: - Helpers

    static func base64URLDecode(_ string: String) -> Data? {
        Base64URL.decode(string)
    }

    static func unquoteStoredValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
            trimmed.hasPrefix("\""),
            trimmed.hasSuffix("\"")
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain both pipes on their own queues *concurrently with the child*, so a
        // child that emits more than the ~64 KB pipe buffer can't block on write and
        // wedge waitUntilExit() (a deadlock the post-exit read pattern is prone to).
        // readDataToEndOfFile() returns when the child closes its end on exit.
        final class CapturedData: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
            var value: Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let outBuffer = CapturedData()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outBuffer.set(stdout.fileHandleForReading.readDataToEndOfFile())
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        let semaphore = DispatchSemaphore(value: 0)
        final class TerminationBox: @unchecked Sendable { var status: Int32 = -1 }
        let box = TerminationBox()
        DispatchQueue.global(qos: .utility).async {
            defer { semaphore.signal() }
            do {
                try process.run()
            } catch {
                return
            }
            process.waitUntilExit()
            box.status = process.terminationStatus
        }
        if semaphore.wait(timeout: .now() + processTimeoutSeconds) == .timedOut {
            // Escalate: SIGTERM, then SIGKILL if the child ignores the polite request.
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            return nil
        }
        guard box.status == 0 else { return nil }
        // The child has exited, so both pipes are at EOF; wait for the drains to flush.
        drainGroup.wait()
        return String(data: outBuffer.value, encoding: .utf8)
    }
}
