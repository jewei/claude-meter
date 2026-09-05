import ClaudeMeterCore
import Darwin
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
    private static let processTerminationQueue = DispatchQueue(
        label: "com.jewei.claudemeter.cursor.process-termination", qos: .utility)

    struct DetectionCacheIdentity: Sendable, Equatable {
        struct FileIdentity: Sendable, Equatable {
            let device: dev_t
            let inode: ino_t
            let mode: mode_t
            let byteCount: off_t
            let modificationSeconds: time_t
            let modificationNanoseconds: Int64
            let changeSeconds: time_t
            let changeNanoseconds: Int64

            init(_ status: stat) {
                self.device = status.st_dev
                self.inode = status.st_ino
                self.mode = status.st_mode
                self.byteCount = status.st_size
                self.modificationSeconds = status.st_mtimespec.tv_sec
                self.modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
                self.changeSeconds = status.st_ctimespec.tv_sec
                self.changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            }
        }

        struct WriteAheadLogIdentity: Sendable, Equatable {
            let path: String
            let file: FileIdentity?
        }

        struct SharedMemoryIdentity: Sendable, Equatable {
            let path: String
            let file: FileIdentity?
            let walIndexHeader: Data?
        }

        let canonicalDatabasePath: String
        let database: FileIdentity
        let writeAheadLogs: [WriteAheadLogIdentity]
        let sharedMemoryFiles: [SharedMemoryIdentity]
    }

    struct CredentialDetection: Sendable, Equatable {
        let credentials: CursorCredentials?
        let canUseStateFileCache: Bool
    }

    private enum RegularFileInspection {
        case missing
        case regular(DetectionCacheIdentity.FileIdentity)
        case unsafe
    }

    private enum SharedMemoryInspection {
        case missing
        case regular(file: DetectionCacheIdentity.FileIdentity, walIndexHeader: Data)
        case unsafe
    }

    private static let walIndexHeaderByteCount = 96

    /// Memoized `detect()` result, keyed on the state DB, WAL, and SHM identities.
    ///
    /// `detect()` runs on every Cursor poll (once a minute), and each call spawns
    /// `sqlite3` against a `globalStorage/state.vscdb` that can be tens of MB.
    /// Cursor normally commits credential changes to the write-ahead log before
    /// SQLite checkpoints the main file. SQLite also updates the memory-mapped
    /// SHM header without a reliable metadata change, so its header is part of the
    /// key too.
    private static let cacheLock = NSLock()
    private static nonisolated(unsafe) var cachedDetection:
        (identity: DetectionCacheIdentity, credentials: CursorCredentials?)?

    private static let stateKeys = [
        "cursorAuth/accessToken",
        "cursorAuth/refreshToken",
        "cursorAuth/cachedEmail",
        "cursorAuth/stripeMembershipType",
    ]

    // MARK: - Detection

    /// Best-effort detection of Cursor credentials. Returns nil when Cursor isn't
    /// installed / signed in. Memoized against the state DB, WAL, and SHM
    /// identities so a 60 s poll loop doesn't spawn `sqlite3` for unchanged data.
    public static func detect() -> CursorCredentials? {
        let path = stateDBPath
        return detect(stateDatabasePath: path) {
            detectUncached(stateDatabasePath: path)
        }
    }

    static func detect(
        stateDatabasePath: String,
        uncachedLoader: () -> CredentialDetection
    ) -> CursorCredentials? {
        let identity = stateDBCacheIdentity(atPath: stateDatabasePath)
        if let identity, let cached = readCachedDetection(identity: identity) { return cached }

        let detection = uncachedLoader()
        if let identity, detection.canUseStateFileCache,
            stateDBCacheIdentity(atPath: stateDatabasePath) == identity
        {
            storeCachedDetection(identity: identity, credentials: detection.credentials)
        }
        return detection.credentials
    }

    /// Identity of all files that can change a read-only SQLite result. Missing
    /// WAL and SHM files are part of the identity, so their creation and removal
    /// invalidate the cache. The SHM signature includes both copies of SQLite's
    /// 48-byte WAL-index header because mmap writes need not change file metadata.
    /// Metadata or header-read errors disable the cache. Non-regular paths also
    /// block SQLite; a short or unstable regular SHM still permits an uncached
    /// SQLite recovery through `stateDBIsSafeForSQLiteRead`.
    static func stateDBCacheIdentity(atPath path: String) -> DetectionCacheIdentity? {
        guard case .regular(let database) = inspectRegularFile(atPath: path),
            let canonicalPath = canonicalPath(forExistingItemAtPath: path)
        else { return nil }

        let walPaths = sidecarPaths(
            suffix: "-wal", databasePath: path, canonicalDatabasePath: canonicalPath)
        var writeAheadLogs: [DetectionCacheIdentity.WriteAheadLogIdentity] = []
        writeAheadLogs.reserveCapacity(walPaths.count)
        for walPath in walPaths {
            switch inspectRegularFile(atPath: walPath) {
            case .missing:
                writeAheadLogs.append(.init(path: walPath, file: nil))
            case .regular(let file):
                writeAheadLogs.append(.init(path: walPath, file: file))
            case .unsafe:
                return nil
            }
        }

        let sharedMemoryPaths = sidecarPaths(
            suffix: "-shm", databasePath: path, canonicalDatabasePath: canonicalPath)
        var sharedMemoryFiles: [DetectionCacheIdentity.SharedMemoryIdentity] = []
        sharedMemoryFiles.reserveCapacity(sharedMemoryPaths.count)
        for sharedMemoryPath in sharedMemoryPaths {
            switch inspectSharedMemoryFile(atPath: sharedMemoryPath) {
            case .missing:
                sharedMemoryFiles.append(
                    .init(path: sharedMemoryPath, file: nil, walIndexHeader: nil))
            case .regular(let file, let walIndexHeader):
                sharedMemoryFiles.append(
                    .init(
                        path: sharedMemoryPath,
                        file: file,
                        walIndexHeader: walIndexHeader
                    ))
            case .unsafe:
                return nil
            }
        }

        return DetectionCacheIdentity(
            canonicalDatabasePath: canonicalPath,
            database: database,
            writeAheadLogs: writeAheadLogs,
            sharedMemoryFiles: sharedMemoryFiles
        )
    }

    /// A regular but short SHM can be a recoverable crash artifact. It is not a
    /// sound cache key until both WAL-index headers exist, but SQLite may open it
    /// and rebuild it. Special files stay rejected before subprocess launch.
    static func stateDBIsSafeForSQLiteRead(atPath path: String) -> Bool {
        guard case .regular = inspectRegularFile(atPath: path),
            let canonicalPath = canonicalPath(forExistingItemAtPath: path)
        else { return false }

        for suffix in ["-wal", "-shm"] {
            let paths = sidecarPaths(
                suffix: suffix,
                databasePath: path,
                canonicalDatabasePath: canonicalPath
            )
            for sidecarPath in paths {
                switch inspectRegularFile(atPath: sidecarPath) {
                case .missing, .regular:
                    continue
                case .unsafe:
                    return false
                }
            }
        }
        return true
    }

    private static func sidecarPaths(
        suffix: String,
        databasePath: String,
        canonicalDatabasePath: String
    ) -> [String] {
        Set([databasePath + suffix, canonicalDatabasePath + suffix]).sorted()
    }

    private static func inspectRegularFile(atPath path: String) -> RegularFileInspection {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .unsafe
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { return .unsafe }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else {
            return .unsafe
        }
        return .regular(.init(status))
    }

    private static func inspectSharedMemoryFile(atPath path: String) -> SharedMemoryInspection {
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .unsafe
        }
        defer { Darwin.close(descriptor) }

        var statusBefore = stat()
        guard Darwin.fstat(descriptor, &statusBefore) == 0,
            (statusBefore.st_mode & S_IFMT) == S_IFREG,
            statusBefore.st_size >= off_t(walIndexHeaderByteCount)
        else { return .unsafe }

        let fileBefore = DetectionCacheIdentity.FileIdentity(statusBefore)
        guard
            let header = readPrefix(
                descriptor: descriptor,
                byteCount: walIndexHeaderByteCount
            )
        else { return .unsafe }

        var statusAfter = stat()
        guard Darwin.fstat(descriptor, &statusAfter) == 0,
            DetectionCacheIdentity.FileIdentity(statusAfter) == fileBefore
        else { return .unsafe }
        return .regular(file: fileBefore, walIndexHeader: header)
    }

    private static func readPrefix(descriptor: Int32, byteCount: Int) -> Data? {
        guard byteCount >= 0 else { return nil }
        guard byteCount > 0 else { return Data() }

        var data = Data(count: byteCount)
        var offset = 0
        let succeeded = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            while offset < byteCount {
                let count = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset))
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    return false
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
        return succeeded ? data : nil
    }

    private static func canonicalPath(forExistingItemAtPath path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.isEmpty ? nil : resolved
    }

    private static func readCachedDetection(
        identity: DetectionCacheIdentity
    ) -> CursorCredentials?? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cachedDetection, cachedDetection.identity == identity else { return nil }
        return .some(cachedDetection.credentials)
    }

    private static func storeCachedDetection(
        identity: DetectionCacheIdentity,
        credentials: CursorCredentials?
    ) {
        cacheLock.lock()
        cachedDetection = (identity, credentials)
        cacheLock.unlock()
    }

    static func resetDetectionCacheForTesting() {
        cacheLock.lock()
        cachedDetection = nil
        cacheLock.unlock()
    }

    private static func detectUncached(stateDatabasePath: String) -> CredentialDetection {
        resolveCredentialDetection(
            stateValues: readStateValues(stateKeys, stateDatabasePath: stateDatabasePath),
            keychainLoader: keychainValue(service:)
        )
    }

    static func resolveCredentialDetection(
        stateValues: [String: String],
        keychainLoader: (String) -> String?
    ) -> CredentialDetection {
        var access = nonEmpty(stateValues["cursorAuth/accessToken"])
        var refresh = nonEmpty(stateValues["cursorAuth/refreshToken"])
        let email = nonEmpty(stateValues["cursorAuth/cachedEmail"])
        let membership = nonEmpty(
            stateValues["cursorAuth/stripeMembershipType"]?.lowercased())

        let needsAccessFallback = access == nil
        let needsRefreshFallback = refresh == nil
        if needsAccessFallback {
            access = nonEmpty(keychainLoader("cursor-access-token"))
        }
        if needsRefreshFallback {
            refresh = nonEmpty(keychainLoader("cursor-refresh-token"))
        }

        let credentials = access.map {
            CursorCredentials(
                accessToken: $0,
                refreshToken: refresh,
                email: email,
                membership: membership
            )
        }
        return CredentialDetection(
            credentials: credentials,
            canUseStateFileCache: !needsAccessFallback && !needsRefreshFallback
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// True when Cursor's state DB exists (filesystem-only; no Keychain/subprocess).
    public static func isStateDBPresent() -> Bool {
        stateDBIsSafeForSQLiteRead(atPath: stateDBPath)
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
            let exp = (object["exp"] as? NSNumber)?.doubleValue,
            exp.isFinite
        else { return nil }
        return boundedProviderDate(timeIntervalSince1970: exp)
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
        readStateValues(keys, stateDatabasePath: stateDBPath)
    }

    static func readStateValues(
        _ keys: [String], stateDatabasePath: String
    ) -> [String: String] {
        guard !keys.isEmpty, stateDBIsSafeForSQLiteRead(atPath: stateDatabasePath) else {
            return [:]
        }
        // Keys are fixed constants, so the inline query is injection-safe.
        let quoted = keys.map { "'\($0)'" }.joined(separator: ", ")
        let query = "SELECT key, value FROM ItemTable WHERE key IN (\(quoted));"
        guard let output = run(sqlite3Path, ["-readonly", stateDatabasePath, query]) else {
            return [:]
        }

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
        run(
            launchPath, arguments, timeout: processTimeoutSeconds,
            launchQueue: DispatchQueue(
                label: "com.jewei.claudemeter.cursor.process-launch", qos: .utility))
    }

    static func run(
        _ launchPath: String, _ arguments: [String], timeout: TimeInterval,
        launchQueue: DispatchQueue
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        // The timeout can expire while launch is queued or while Process.run() is
        // still starting the child. Only a successful launch permits termination.
        final class LaunchState: @unchecked Sendable {
            private let lock = NSLock()
            private var cancelled = false
            private var launched = false
            // Written before completion.signal(), read only after a successful wait.
            var status: Int32 = -1

            var mayLaunch: Bool { lock.withLock { !cancelled } }

            func didLaunch() -> Bool {
                lock.withLock {
                    launched = true
                    return cancelled
                }
            }

            func cancel() -> Bool {
                lock.withLock {
                    cancelled = true
                    return launched
                }
            }
        }
        let state = LaunchState()
        let completion = DispatchSemaphore(value: 0)
        let outBuffer = BoundedProcessOutputCapture()

        @Sendable func stopLaunchedProcess() {
            guard process.isRunning else { return }
            process.terminate()
            processTerminationQueue.asyncAfter(deadline: .now() + 0.4) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        launchQueue.async {
            defer { completion.signal() }
            guard state.mayLaunch else {
                try? stdout.fileHandleForWriting.close()
                return
            }
            do {
                try process.run()
            } catch {
                try? stdout.fileHandleForWriting.close()
                return
            }
            try? stdout.fileHandleForWriting.close()
            if state.didLaunch() { stopLaunchedProcess() }

            // Start the reader after launch, on its own queue. Blocking pipe reads
            // must not occupy shared workers needed to launch the writer. Keep
            // draining after overflow, but never return truncated credentials.
            let drained = DispatchSemaphore(value: 0)
            DispatchQueue(
                label: "com.jewei.claudemeter.cursor.process-stdout", qos: .utility
            ).async {
                defer { drained.signal() }
                while true {
                    let chunk = stdout.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { break }
                    outBuffer.append(chunk)
                }
            }
            process.waitUntilExit()
            state.status = process.terminationStatus
            drained.wait()
        }
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            if state.cancel() { stopLaunchedProcess() }
            return nil
        }
        guard state.status == 0, let data = outBuffer.data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
