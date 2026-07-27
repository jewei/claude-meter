import ClaudeMeterCore
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
    private static let processTimeoutSeconds: TimeInterval = 10

    /// Memoized `detect()` result, keyed on the state DB's mtime + size.
    ///
    /// `detect()` runs on every Cursor poll (once a minute), and each call spawns
    /// `sqlite3` against a `globalStorage/state.vscdb` that can be tens of MB.
    /// Cursor's stored credentials only change when the user signs in or the app
    /// rotates them — both of which touch the file — so the stamp is a sound key.
    private static let cacheLock = NSLock()
    private static nonisolated(unsafe) var cachedDetection:
        (stamp: String, credentials: CursorCredentials?)?

    private static let stateKeys = [
        "cursorAuth/accessToken",
        "cursorAuth/refreshToken",
        "cursorAuth/cachedEmail",
        "cursorAuth/stripeMembershipType",
    ]

    // MARK: - Detection

    /// Best-effort detection of Cursor credentials. Returns nil when Cursor isn't
    /// installed / signed in. Memoized against the state DB's mtime + size so a
    /// 60 s poll loop doesn't spawn `sqlite3` every cycle for unchanged data.
    public static func detect() -> CursorCredentials? {
        let stamp = stateDBStamp()
        if let stamp, let cached = readCachedDetection(stamp: stamp) { return cached }
        let credentials = detectUncached()
        if let stamp { storeCachedDetection(stamp: stamp, credentials: credentials) }
        return credentials
    }

    /// Identity of the state DB's current contents; `nil` when it doesn't exist
    /// (in which case we never cache — the Keychain fallback is the only source
    /// and has no cheap change signal).
    private static func stateDBStamp() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: stateDBPath),
            let modDate = attrs[.modificationDate] as? Date
        else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(modDate.timeIntervalSince1970)|\(size)"
    }

    private static func readCachedDetection(stamp: String) -> CursorCredentials?? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cachedDetection, cachedDetection.stamp == stamp else { return nil }
        return .some(cachedDetection.credentials)
    }

    private static func storeCachedDetection(stamp: String, credentials: CursorCredentials?) {
        cacheLock.lock()
        cachedDetection = (stamp, credentials)
        cacheLock.unlock()
    }

    static func resetDetectionCacheForTesting() {
        cacheLock.lock()
        cachedDetection = nil
        cacheLock.unlock()
    }

    private static func detectUncached() -> CursorCredentials? {
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

    /// Reads a Cursor-owned Keychain item through the shared no-UI gateway.
    ///
    /// Deliberately *not* `/usr/bin/security find-generic-password -w`: that is a
    /// secret read with no non-interactive policy, so an item whose ACL doesn't
    /// list this app raises the legacy Allow/Deny dialog and blocks the subprocess
    /// until the user answers — and it sidesteps the fail-closed test gateway,
    /// letting a unit test touch the developer's real login Keychain. Same policy
    /// `OAuthKeychain` applies to Claude Code's items.
    private static func keychainValue(service: String) -> String? {
        guard let value = KeychainGateway.readGenericPassword(service: service) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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
