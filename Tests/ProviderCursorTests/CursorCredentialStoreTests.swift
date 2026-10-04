import Darwin
import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCursor

@Suite struct CursorCredentialStoreTests {
    private func credentials(_ lookup: CursorCredentialLookup) -> CursorCredentials? {
        if case .found(let credentials) = lookup { return credentials }
        return nil
    }

    private func failure(_ lookup: CursorCredentialLookup) -> CursorFailure? {
        if case .unreadable(let failure) = lookup { return failure }
        return nil
    }

    @Test func readsTheFourKeysWithoutChangingTheDatabase() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try home.write([
            "cursorAuth/accessToken": .text("  \"access-token\"\n"),
            "cursorAuth/refreshToken": .text("refresh-token"),
            "cursorAuth/cachedEmail": .text("alpha@example.com"),
            "cursorAuth/stripeMembershipType": .text("PRO"),
            "unrelated/key": .text("ignored"),
        ])
        let folder = home.database.deletingLastPathComponent()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: home.database.path)
        let keychain = FakeKeychain()

        let lookup = try await CursorCredentialStore(home: home.url, keychain: keychain).read()

        let found = try #require(credentials(lookup))
        #expect(found.accessToken == "access-token")
        #expect(found.membership == "PRO")
        #expect(found.source == .database)
        #expect(found.hasRefreshToken)
        #expect(keychain.readServices.isEmpty)
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: home.database.path)
        #expect(
            attributesAfter[.modificationDate] as? Date == attributesBefore[.modificationDate]
                as? Date)
        #expect(attributesAfter[.size] as? Int == attributesBefore[.size] as? Int)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == filesBefore
        )
    }

    @Test func emptyTableOrRefreshTokenAloneMeansSignedOut() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let store = CursorCredentialStore(home: home.url, keychain: FakeKeychain())
        try home.write([:])
        #expect(try await store.read().ownerStatus == .signedOut)
        try home.write(["cursorAuth/refreshToken": .text("refresh-token")])
        #expect(try await store.read().ownerStatus == .signedOut)
    }

    @Test func missingDatabaseFallsBackToTheKeychainWithoutCreatingFiles() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let keychain = FakeKeychain()
        let store = CursorCredentialStore(home: home.url, keychain: keychain)

        #expect(try await store.read().ownerStatus == .signedOut)
        keychain.store("\"keychain-token\"\n", service: "cursor-access-token")
        let found = try #require(credentials(try await store.read()))

        #expect(found.accessToken == "keychain-token")
        #expect(found.source == .keychain)
        #expect(keychain.readServices == ["cursor-access-token", "cursor-access-token"])
        #expect(!FileManager.default.fileExists(atPath: home.database.path))
    }

    @Test func keychainIsReadOnlyForAMissingAccessToken() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try home.write(["cursorAuth/stripeMembershipType": .text("pro")])
        let keychain = FakeKeychain()
        keychain.store("keychain-token", service: "cursor-access-token")
        keychain.store("keychain-refresh", service: "cursor-refresh-token")

        let found = try #require(
            credentials(try await CursorCredentialStore(home: home.url, keychain: keychain).read()))

        #expect(found.accessToken == "keychain-token")
        #expect(found.membership == "pro")
        #expect(keychain.readServices == ["cursor-access-token"])
        #expect(
            keychain.storedPassword(service: "cursor-access-token", account: "user")
                == "keychain-token")
    }

    @Test func eachReadSeesTheCurrentValues() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let store = CursorCredentialStore(home: home.url, keychain: FakeKeychain())
        try home.write(token: "first-token")
        #expect(credentials(try await store.read())?.accessToken == "first-token")
        try home.write(token: "second-token")
        #expect(credentials(try await store.read())?.accessToken == "second-token")
    }

    @Test func readsUTF16BlobsFromTheDatabase() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let utf16 = try #require("utf16-token".data(using: .utf16LittleEndian))
        try home.write(["cursorAuth/accessToken": .blob(utf16)])
        let found = credentials(
            try await CursorCredentialStore(home: home.url, keychain: FakeKeychain()).read())
        #expect(found?.accessToken == "utf16-token")
    }

    /// A WAL reader sees the last commit, never a write that Cursor has not committed.
    @Test func aWALReadSeesCommittedDataOnly() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try home.write(token: "committed-token")
        let store = CursorCredentialStore(home: home.url, keychain: FakeKeychain())
        let writer = try home.beginWrite(token: "pending-token")

        #expect(credentials(try await store.read())?.accessToken == "committed-token")
        home.commit(writer)
        #expect(credentials(try await store.read())?.accessToken == "pending-token")
    }

    @Test func readsTextFromAUTF16Database() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try home.write(
            [
                "cursorAuth/accessToken": .text("utf16-database-token"),
                "cursorAuth/stripeMembershipType": .text("pro"),
            ], encoding: "UTF-16le")
        let store = CursorCredentialStore(home: home.url, keychain: FakeKeychain())
        let found = credentials(try await store.read())
        #expect(found?.accessToken == "utf16-database-token")
        #expect(found?.membership == "pro")
    }

    /// SQLite refuses a value above 1 MiB. The database is unreadable, not empty, so the
    /// Keychain is not asked.
    @Test func aValueAboveTheLimitMakesTheDatabaseUnreadable() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let huge = String(repeating: "x", count: Int(SQLiteReader.maxValueBytes) + 1)
        try home.write(["cursorAuth/accessToken": .text(huge)])
        let keychain = FakeKeychain()
        keychain.store("keychain-token", service: "cursor-access-token")

        let lookup = try await CursorCredentialStore(home: home.url, keychain: keychain).read()

        #expect(failure(lookup) == .credentialsUnreadable)
        #expect(keychain.readServices.isEmpty)
    }

    /// Rules 1 and 5: a busy database can still hold a token, and the Keychain item can belong
    /// to another login, so the read fails at once and never asks the Keychain.
    @Test func aBusyDatabaseNeverFallsBackToTheKeychain() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let databaseToken = CursorFixture.token(subject: "auth0|user_A")
        try home.write(["cursorAuth/accessToken": .text(databaseToken)], journalMode: "DELETE")
        let keychain = FakeKeychain()
        keychain.store(CursorFixture.token(subject: "auth0|user_B"), service: "cursor-access-token")
        let store = CursorCredentialStore(home: home.url, keychain: keychain)
        let lock = try home.lockExclusively()

        let busy = try await store.read()
        #expect(failure(busy) == .credentialsBusy)
        #expect(busy.ownerStatus == .unknown)
        #expect(keychain.readServices.isEmpty)
        #expect(
            try await store.signInStatus() == .unknown(CursorFailure.credentialsBusy.issue.message))

        home.unlock(lock)
        let found = try #require(credentials(try await store.read()))
        #expect(found.accessToken == databaseToken)
        #expect(keychain.readServices.isEmpty)
    }

    @Test func unusableDatabasesNeverFallBackToTheKeychain() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try home.directory.write(
            "not a database",
            to: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        let keychain = FakeKeychain()
        keychain.store("keychain-token", service: "cursor-access-token")
        let store = CursorCredentialStore(home: home.url, keychain: keychain)

        #expect(failure(try await store.read()) == .credentialsUnreadable)
        #expect(keychain.readServices.isEmpty)
        #expect(
            try await store.signInStatus()
                == .unknown(CursorFailure.credentialsUnreadable.issue.message))
    }

    @Test func aDirectoryAsTheDatabaseIsUnreadable() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try FileManager.default.createDirectory(
            at: home.database, withIntermediateDirectories: true)
        let keychain = FakeKeychain()
        keychain.store("keychain-token", service: "cursor-access-token")
        let lookup = try await CursorCredentialStore(home: home.url, keychain: keychain).read()
        #expect(failure(lookup) == .credentialsUnreadable)
        #expect(keychain.readServices.isEmpty)
    }

    @Test func aFIFOIsRejectedWithoutBlocking() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try FileManager.default.createDirectory(
            at: home.database.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(mkfifo(home.database.path, 0o600) == 0)
        let lookup = try await CursorCredentialStore(home: home.url, keychain: FakeKeychain())
            .read()
        #expect(failure(lookup) == .credentialsUnreadable)
    }

    /// SQLite opens the sidecars of a linked database's target, so a FIFO there must be
    /// rejected before SQLite blocks on it.
    @Test func aLinkedDatabaseIsCheckedAtItsTarget() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try home.write(["cursorAuth/accessToken": .text("linked-token")], journalMode: "DELETE")
        let target = try home.directory.makeDirectory("other").appending(path: "real.vscdb")
        try FileManager.default.moveItem(at: home.database, to: target)
        try FileManager.default.createSymbolicLink(at: home.database, withDestinationURL: target)
        let store = CursorCredentialStore(home: home.url, keychain: FakeKeychain())
        #expect(credentials(try await store.read())?.accessToken == "linked-token")

        // SQLite opens an existing `-journal` to check whether it is hot.
        #expect(mkfifo(target.path + "-journal", 0o600) == 0)
        let started = ContinuousClock.now
        let lookup = try await store.read()
        #expect(failure(lookup) == .credentialsUnreadable)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    /// `readonly_shm=1` cannot create a missing `-shm`, so the read fails and writes nothing.
    @Test func aWALDatabaseWithoutItsSharedMemoryFileFailsWithoutCreatingFiles() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try home.write(token: "wal-token")
        try? FileManager.default.removeItem(atPath: home.database.path + "-shm")
        try? FileManager.default.removeItem(atPath: home.database.path + "-wal")
        let folder = home.database.deletingLastPathComponent()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        let lookup = try await CursorCredentialStore(home: home.url, keychain: FakeKeychain())
            .read()

        #expect(failure(lookup) == .credentialsUnreadable)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == filesBefore
        )
    }

    @Test(arguments: [
        (KeychainError.unavailable, CursorFailure.keychainUnavailable),
        (.denied, .keychainDenied),
        (.failure(status: -25_300), .keychainFailed),
    ])
    func keychainErrorsAreUnknownNotSignedOut(error: KeychainError, expected: CursorFailure)
        async throws
    {
        let home = try CursorHome()
        defer { home.remove() }
        let keychain = FakeKeychain()
        keychain.failure = error
        let store = CursorCredentialStore(home: home.url, keychain: keychain)
        let lookup = try await store.read()
        #expect(failure(lookup) == expected)
        #expect(lookup.ownerStatus == .unknown)
        #expect(try await store.signInStatus() == .unknown(expected.issue.message))
    }

    /// `signInStatus` sees only that the item exists, so an item without a usable token must
    /// not read as a sign-out, or onboarding and the card disagree.
    @Test(arguments: [Data(), Data("  \"\"  ".utf8), Data([0xFE, 0xFF, 0xD8, 0x00])])
    func aKeychainItemWithoutAUsableTokenIsUnreadable(stored: Data) async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let keychain = FakeKeychain()
        try keychain.setPassword(stored, service: "cursor-access-token", account: "user")
        let store = CursorCredentialStore(home: home.url, keychain: keychain)

        let lookup = try await store.read()

        #expect(failure(lookup) == .credentialsUnreadable)
        #expect(lookup.ownerStatus == .unknown)
        #expect(try await store.signInStatus() == .signedIn)
    }

    @Test func aSlowReadTimesOutWithANeutralMessage() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let store = CursorCredentialStore(
            home: home.url, keychain: SlowKeychain(delay: 0.5), readTimeout: .milliseconds(50))

        let lookup = try await store.read()

        #expect(failure(lookup) == .credentialsTimedOut)
        #expect(
            failure(lookup)?.issue.message
                == "Reading Cursor credentials took too long. Claude Meter will try again soon.")
        #expect(lookup.ownerStatus == .unknown)
    }

    /// Rule 8: a cancelled read stops before the Keychain.
    @Test func aCancelledReadNeverReadsTheKeychain() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let keychain = FakeKeychain()
        keychain.store("keychain-token", service: "cursor-access-token")
        let store = CursorCredentialStore(home: home.url, keychain: keychain)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.read()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(keychain.readServices.isEmpty)
    }

    @Test func signInStatusReadsNoKeychainSecret() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let keychain = FakeKeychain()
        let store = CursorCredentialStore(home: home.url, keychain: keychain)

        #expect(try await store.signInStatus() == .signedOut)
        keychain.store("keychain-token", service: "cursor-access-token")
        #expect(try await store.signInStatus() == .signedIn)
        #expect(keychain.readServices.isEmpty)

        try home.write(token: "database-token")
        keychain.failure = .unavailable
        #expect(try await store.signInStatus() == .signedIn)
        #expect(keychain.readServices.isEmpty)
    }

    @Test func decodesEveryStoredEncoding() throws {
        let expected = "token"
        let utf8 = Data("token".utf8)
        let utf16LE = try #require("token".data(using: .utf16LittleEndian))
        let utf16WithMark = try #require("token".data(using: .utf16))
        let utf16BE = Data([0xFE, 0xFF]) + (try #require("token".data(using: .utf16BigEndian)))
        for data in [utf8, utf16LE, utf16WithMark, utf16BE] {
            #expect(CursorStoredValue.text(data) == expected)
        }
        #expect(CursorStoredValue.text(Data("a,b\n\"c\"".utf8)) == "a,b\n\"c\"")
        #expect(CursorStoredValue.text(Data("\"\"".utf8)) == nil)
        #expect(CursorStoredValue.text(Data([0xFF])) == nil)
        #expect(CursorStoredValue.text(Data([0xFE, 0xFF, 0xD8, 0x00])) == nil)
        #expect(CursorStoredValue.text(Data()) == nil)
    }

    @Test func ownerUsesTheSubjectAndElseTheToken() {
        let first = CursorCredentials(
            accessToken: CursorFixture.token(expiresAt: .reference(.hours(1))), membership: nil,
            source: .database, hasRefreshToken: false)
        let renewed = CursorCredentials(
            accessToken: CursorFixture.token(expiresAt: .reference(.hours(2))), membership: nil,
            source: .keychain, hasRefreshToken: true)
        let opaque = CursorCredentials(
            accessToken: "opaque", membership: nil, source: .database, hasRefreshToken: false)

        #expect(first.owner == CursorFixture.ownerOf(subject: "auth0|user_123"))
        #expect(first.owner == renewed.owner)
        #expect(opaque.owner == .credential(Digest.sha256(parts: ["cursor", "opaque"])))
        #expect(opaque.expiresAt == nil)
        #expect(!opaque.isExpired(at: .reference()))
    }

    @Test func aNonNumericExpiryIsUnknown() {
        let token = JWTFixture.token(["sub": "auth0|user_123", "exp": true])
        let credentials = CursorCredentials(
            accessToken: token, membership: nil, source: .database, hasRefreshToken: false)
        #expect(credentials.expiresAt == nil)
        #expect(!credentials.isExpired(at: .reference()))
    }
}

/// A Keychain whose reads block for `delay` seconds, as a stuck Keychain daemon would.
private struct SlowKeychain: Keychain {
    let delay: TimeInterval

    func password(service: String, account: String?) throws(KeychainError) -> Data? {
        Thread.sleep(forTimeInterval: delay)
        return nil
    }

    func items(servicePrefix: String, account: String?) throws(KeychainError) -> [KeychainItem] {
        Thread.sleep(forTimeInterval: delay)
        return []
    }

    func setPassword(_ password: Data, service: String, account: String) throws(KeychainError) {}

    func deletePassword(service: String, account: String) throws(KeychainError) {}
}
