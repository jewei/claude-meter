import Darwin
import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCursor

@Suite struct CursorCredentialStoreTests {
    func credentials(_ lookup: CursorCredentialLookup) -> CursorCredentials? {
        if case .found(let credentials) = lookup { return credentials }
        return nil
    }

    func failure(_ lookup: CursorCredentialLookup) -> CursorFailure? {
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

    /// Diagnostics need only whether a refresh token exists, so its value never leaves SQLite.
    @Test func theRefreshTokenIsNeverLoaded() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try home.write(token: "access-token")
        let rows = try SQLiteReader.rows(
            in: home.database, query: CursorCredentialStore.query,
            bindings: CursorCredentialStore.keys)
        let refresh = rows.first { $0.first == Data("cursorAuth/refreshToken".utf8) }
        #expect(refresh?.last == Data("1".utf8))
        #expect(!rows.contains { $0.last == Data("refresh-token".utf8) })

        try home.write([
            "cursorAuth/accessToken": .text("access-token"), "cursorAuth/refreshToken": .text(""),
        ])
        let store = CursorCredentialStore(home: home.url, keychain: FakeKeychain())
        #expect(credentials(try await store.read())?.hasRefreshToken == false)
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
