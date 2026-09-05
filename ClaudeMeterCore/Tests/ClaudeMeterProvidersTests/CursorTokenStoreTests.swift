import Darwin
import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Cursor token store cache", .serialized)
struct CursorTokenStoreTests {
    private enum FixtureError: Error {
        case sqliteFailed(Int32)
    }

    private func makeDatabase() throws -> (directory: URL, database: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("state.vscdb")
        try Data("database".utf8).write(to: database)
        return (directory, database)
    }

    private func credentials(_ token: String) -> CursorCredentials {
        CursorCredentials(
            accessToken: token,
            refreshToken: "refresh-\(token)",
            email: nil,
            membership: nil
        )
    }

    private func runSQLite(database: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", database.path, sql]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.sqliteFailed(process.terminationStatus)
        }
    }

    @Test func timeoutBeforeProcessLaunchDoesNotLaunchAnAbandonedCommand() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("unexpected-launch")
        let launchQueue = DispatchQueue(label: "CursorTokenStoreTests.delayed-launch")
        launchQueue.suspend()
        let result = CursorTokenStore.run(
            "/usr/bin/touch", [marker.path], timeout: 0.01, launchQueue: launchQueue)
        launchQueue.resume()
        launchQueue.sync {}

        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func failedProcessLaunchReturnsNoOutput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("invalid-executable")
        try Data("Not an executable format".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let launchQueue = DispatchQueue(label: "CursorTokenStoreTests.failed-launch")

        #expect(
            CursorTokenStore.run(executable.path, [], timeout: 1, launchQueue: launchQueue) == nil)
        launchQueue.sync {}
    }

    @Test func sqliteOutputBeyondTheLimitIsDrainedAndRejected() {
        let launchQueue = DispatchQueue(label: "CursorTokenStoreTests.large-output")
        let result = CursorTokenStore.run(
            "/usr/bin/sqlite3", ["-batch", ":memory:", "SELECT hex(zeroblob(600000));"],
            timeout: 3, launchQueue: launchQueue)
        let completed = DispatchSemaphore(value: 0)
        launchQueue.async { completed.signal() }

        #expect(result == nil)
        #expect(completed.wait(timeout: .now() + 1) == .success)
    }

    @Test func unchangedDatabaseAndWalReuseCachedDetection() throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        CursorTokenStore.resetDetectionCacheForTesting()
        defer { CursorTokenStore.resetDetectionCacheForTesting() }

        var loadCount = 0
        let load = {
            loadCount += 1
            return CursorTokenStore.CredentialDetection(
                credentials: credentials("token-\(loadCount)"),
                canUseStateFileCache: true
            )
        }

        let first = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        let second = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)

        #expect(first == credentials("token-1"))
        #expect(second == first)
        #expect(loadCount == 1)
    }

    @Test func walCreationChangeAndRemovalInvalidateCachedDetection() throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        CursorTokenStore.resetDetectionCacheForTesting()
        defer { CursorTokenStore.resetDetectionCacheForTesting() }

        let wal = URL(fileURLWithPath: fixture.database.path + "-wal")
        var loadCount = 0
        let load = {
            loadCount += 1
            return CursorTokenStore.CredentialDetection(
                credentials: credentials("token-\(loadCount)"),
                canUseStateFileCache: true
            )
        }

        let beforeWal = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        try Data("wal-one".utf8).write(to: wal)
        let afterCreation = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        let unchangedWal = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        try Data("wal-two-is-longer".utf8).write(to: wal)
        let afterChange = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        try FileManager.default.removeItem(at: wal)
        let afterRemoval = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)

        #expect(beforeWal == credentials("token-1"))
        #expect(afterCreation == credentials("token-2"))
        #expect(unchangedWal == afterCreation)
        #expect(afterChange == credentials("token-3"))
        #expect(afterRemoval == credentials("token-4"))
        #expect(loadCount == 4)
    }

    @Test func shmCreationHeaderChangeAndRemovalInvalidateCachedDetection() throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        CursorTokenStore.resetDetectionCacheForTesting()
        defer { CursorTokenStore.resetDetectionCacheForTesting() }

        let shm = URL(fileURLWithPath: fixture.database.path + "-shm")
        var loadCount = 0
        let load = {
            loadCount += 1
            return CursorTokenStore.CredentialDetection(
                credentials: credentials("token-\(loadCount)"),
                canUseStateFileCache: true
            )
        }

        let beforeShm = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        var header = Data(repeating: 0, count: 136)
        try header.write(to: shm)
        let afterCreation = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        let unchangedShm = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        header[8] = 1
        try header.write(to: shm)
        let afterHeaderChange = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        try FileManager.default.removeItem(at: shm)
        let afterRemoval = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)

        #expect(beforeShm == credentials("token-1"))
        #expect(afterCreation == credentials("token-2"))
        #expect(unchangedShm == afterCreation)
        #expect(afterHeaderChange == credentials("token-3"))
        #expect(afterRemoval == credentials("token-4"))
        #expect(loadCount == 4)
    }

    @Test func symlinkedDatabaseObservesSidecarsBesideResolvedTarget() throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        CursorTokenStore.resetDetectionCacheForTesting()
        defer { CursorTokenStore.resetDetectionCacheForTesting() }

        let link = fixture.directory.appendingPathComponent("linked.vscdb")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: fixture.database.lastPathComponent
        )
        let targetWal = URL(fileURLWithPath: fixture.database.path + "-wal")
        let targetShm = URL(fileURLWithPath: fixture.database.path + "-shm")
        var loadCount = 0
        let load = {
            loadCount += 1
            return CursorTokenStore.CredentialDetection(
                credentials: credentials("token-\(loadCount)"),
                canUseStateFileCache: true
            )
        }

        let beforeWal = CursorTokenStore.detect(
            stateDatabasePath: link.path, uncachedLoader: load)
        try Data("target-wal".utf8).write(to: targetWal)
        let afterWal = CursorTokenStore.detect(
            stateDatabasePath: link.path, uncachedLoader: load)
        try Data(repeating: 0, count: 136).write(to: targetShm)
        let afterShm = CursorTokenStore.detect(
            stateDatabasePath: link.path, uncachedLoader: load)

        #expect(beforeWal == credentials("token-1"))
        #expect(afterWal == credentials("token-2"))
        #expect(afterShm == credentials("token-3"))
        #expect(loadCount == 3)
    }

    @Test func specialDatabaseOrWalDisablesMemoization() throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        CursorTokenStore.resetDetectionCacheForTesting()
        defer { CursorTokenStore.resetDetectionCacheForTesting() }

        let wal = URL(fileURLWithPath: fixture.database.path + "-wal")
        #expect(wal.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)
        #expect(CursorTokenStore.stateDBCacheIdentity(atPath: fixture.database.path) == nil)
        #expect(
            CursorTokenStore.readStateValues(
                ["cursorAuth/accessToken"], stateDatabasePath: fixture.database.path
            ).isEmpty
        )

        var loadCount = 0
        let load = {
            loadCount += 1
            return CursorTokenStore.CredentialDetection(
                credentials: credentials("token-\(loadCount)"),
                canUseStateFileCache: true
            )
        }
        _ = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        _ = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        #expect(loadCount == 2)

        try FileManager.default.removeItem(at: wal)
        try FileManager.default.removeItem(at: fixture.database)
        #expect(
            fixture.database.path.withCString {
                Darwin.mkfifo($0, S_IRUSR | S_IWUSR)
            } == 0
        )
        #expect(CursorTokenStore.stateDBCacheIdentity(atPath: fixture.database.path) == nil)
    }

    @Test func specialSharedMemoryFileDisablesMemoization() throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        CursorTokenStore.resetDetectionCacheForTesting()
        defer { CursorTokenStore.resetDetectionCacheForTesting() }

        let shm = URL(fileURLWithPath: fixture.database.path + "-shm")
        #expect(shm.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)
        #expect(CursorTokenStore.stateDBCacheIdentity(atPath: fixture.database.path) == nil)
        #expect(
            CursorTokenStore.readStateValues(
                ["cursorAuth/accessToken"], stateDatabasePath: fixture.database.path
            ).isEmpty
        )

        var loadCount = 0
        let load = {
            loadCount += 1
            return CursorTokenStore.CredentialDetection(
                credentials: credentials("token-\(loadCount)"),
                canUseStateFileCache: true
            )
        }
        _ = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        _ = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        #expect(loadCount == 2)
    }

    @Test func shortRegularSharedMemoryAllowsReadButDisablesMemoization() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state.vscdb")
        try runSQLite(
            database: database,
            sql: """
                CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT);
                INSERT INTO ItemTable VALUES('cursorAuth/accessToken', 'db-access');
                INSERT INTO ItemTable VALUES('cursorAuth/refreshToken', 'db-refresh');
                """
        )
        let shm = URL(fileURLWithPath: database.path + "-shm")
        try Data(repeating: 0, count: 48).write(to: shm)

        #expect(CursorTokenStore.stateDBIsSafeForSQLiteRead(atPath: database.path))
        #expect(CursorTokenStore.stateDBCacheIdentity(atPath: database.path) == nil)
        let values = CursorTokenStore.readStateValues(
            ["cursorAuth/accessToken", "cursorAuth/refreshToken"],
            stateDatabasePath: database.path
        )
        #expect(values["cursorAuth/accessToken"] == "db-access")
        #expect(values["cursorAuth/refreshToken"] == "db-refresh")

        try Data(repeating: 0, count: 48).write(to: shm)
        CursorTokenStore.resetDetectionCacheForTesting()
        defer { CursorTokenStore.resetDetectionCacheForTesting() }
        var loadCount = 0
        let load = {
            loadCount += 1
            return CursorTokenStore.CredentialDetection(
                credentials: credentials("token-\(loadCount)"),
                canUseStateFileCache: true
            )
        }
        _ = CursorTokenStore.detect(
            stateDatabasePath: database.path, uncachedLoader: load)
        _ = CursorTokenStore.detect(
            stateDatabasePath: database.path, uncachedLoader: load)
        #expect(loadCount == 2)
    }

    @Test func identityChangeDuringDetectionPreventsCacheStorage() throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        CursorTokenStore.resetDetectionCacheForTesting()
        defer { CursorTokenStore.resetDetectionCacheForTesting() }

        let shm = URL(fileURLWithPath: fixture.database.path + "-shm")
        var loadCount = 0
        let load = {
            loadCount += 1
            if loadCount == 1 {
                try? Data(repeating: 0, count: 136).write(to: shm)
            }
            return CursorTokenStore.CredentialDetection(
                credentials: credentials("token-\(loadCount)"),
                canUseStateFileCache: true
            )
        }

        let changedDuringFirstRead = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        let secondRead = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        let cachedSecondRead = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)

        #expect(changedDuringFirstRead == credentials("token-1"))
        #expect(secondRead == credentials("token-2"))
        #expect(cachedSecondRead == secondRead)
        #expect(loadCount == 2)
    }

    @Test func concurrentWalCommitInvalidatesRealDatabaseDetection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state.vscdb")
        try runSQLite(
            database: database,
            sql: """
                PRAGMA journal_mode=WAL;
                PRAGMA wal_autocheckpoint=0;
                CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT);
                INSERT INTO ItemTable VALUES('cursorAuth/accessToken', 'old-access');
                INSERT INTO ItemTable VALUES('cursorAuth/refreshToken', 'old-refresh');
                """
        )

        let reader = Process()
        let readerInput = Pipe()
        let readerOutput = Pipe()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        reader.arguments = ["-batch", database.path]
        reader.standardInput = readerInput
        reader.standardOutput = readerOutput
        reader.standardError = FileHandle.nullDevice
        try reader.run()
        defer {
            try? readerInput.fileHandleForWriting.close()
            if reader.isRunning { reader.terminate() }
            reader.waitUntilExit()
        }
        try readerInput.fileHandleForWriting.write(
            contentsOf: Data("BEGIN; SELECT 'reader-ready';\n".utf8))
        let readyData = readerOutput.fileHandleForReading.availableData
        #expect(String(data: readyData, encoding: .utf8)?.contains("reader-ready") == true)

        CursorTokenStore.resetDetectionCacheForTesting()
        defer { CursorTokenStore.resetDetectionCacheForTesting() }
        let loadFromDatabase = {
            CursorTokenStore.resolveCredentialDetection(
                stateValues: CursorTokenStore.readStateValues(
                    ["cursorAuth/accessToken", "cursorAuth/refreshToken"],
                    stateDatabasePath: database.path
                ),
                keychainLoader: { _ in nil }
            )
        }

        let identityBefore = try #require(
            CursorTokenStore.stateDBCacheIdentity(atPath: database.path))
        let old = CursorTokenStore.detect(
            stateDatabasePath: database.path,
            uncachedLoader: loadFromDatabase
        )
        try runSQLite(
            database: database,
            sql: """
                PRAGMA wal_autocheckpoint=0;
                UPDATE ItemTable SET value = 'new-access'
                  WHERE key = 'cursorAuth/accessToken';
                UPDATE ItemTable SET value = 'new-refresh'
                  WHERE key = 'cursorAuth/refreshToken';
                """
        )
        let identityAfter = try #require(
            CursorTokenStore.stateDBCacheIdentity(atPath: database.path))
        let new = CursorTokenStore.detect(
            stateDatabasePath: database.path,
            uncachedLoader: loadFromDatabase
        )

        #expect(old?.accessToken == "old-access")
        #expect(new?.accessToken == "new-access")
        #expect(new?.refreshToken == "new-refresh")
        #expect(identityAfter != identityBefore)
        #expect(
            identityAfter.sharedMemoryFiles.compactMap(\.walIndexHeader)
                != identityBefore.sharedMemoryFiles.compactMap(\.walIndexHeader)
        )
    }

    @Test func keychainFallbackMakesDetectionNonCacheable() throws {
        var requestedServices: [String] = []
        let stateOnly = CursorTokenStore.resolveCredentialDetection(
            stateValues: [
                "cursorAuth/accessToken": "db-access",
                "cursorAuth/refreshToken": "db-refresh",
            ]
        ) { service in
            requestedServices.append(service)
            return nil
        }
        #expect(stateOnly.canUseStateFileCache)
        #expect(requestedServices.isEmpty)

        let refreshFallback = CursorTokenStore.resolveCredentialDetection(
            stateValues: ["cursorAuth/accessToken": "db-access"]
        ) { service in
            requestedServices.append(service)
            return service == "cursor-refresh-token" ? "keychain-refresh" : nil
        }
        #expect(refreshFallback.credentials?.refreshToken == "keychain-refresh")
        #expect(refreshFallback.canUseStateFileCache == false)
        #expect(requestedServices == ["cursor-refresh-token"])

        requestedServices.removeAll()
        let accessFallback = CursorTokenStore.resolveCredentialDetection(
            stateValues: ["cursorAuth/refreshToken": "db-refresh"]
        ) { service in
            requestedServices.append(service)
            return service == "cursor-access-token" ? "keychain-access" : nil
        }
        #expect(accessFallback.credentials?.accessToken == "keychain-access")
        #expect(accessFallback.canUseStateFileCache == false)
        #expect(requestedServices == ["cursor-access-token"])
    }

    @Test func keychainDerivedResultIsNotStoredInStateFileCache() throws {
        let fixture = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        CursorTokenStore.resetDetectionCacheForTesting()
        defer { CursorTokenStore.resetDetectionCacheForTesting() }

        var loadCount = 0
        let load = {
            loadCount += 1
            return CursorTokenStore.CredentialDetection(
                credentials: credentials("keychain-\(loadCount)"),
                canUseStateFileCache: false
            )
        }

        let first = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)
        let second = CursorTokenStore.detect(
            stateDatabasePath: fixture.database.path, uncachedLoader: load)

        #expect(first == credentials("keychain-1"))
        #expect(second == credentials("keychain-2"))
        #expect(loadCount == 2)
    }
}
