import Darwin
import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCursor

// Serialized: parallel reads can pass `BlockingIO.capacity`, which rejects work at once.
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

    @Test func busyDatabaseIsTemporaryAndTheKeychainStillWorks() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try home.write(["cursorAuth/accessToken": .text("database-token")], journalMode: "DELETE")
        let keychain = FakeKeychain()
        let store = CursorCredentialStore(home: home.url, keychain: keychain)
        let lock = try home.lockExclusively()

        let busy = try await store.read()
        #expect(failure(busy) == .credentialsBusy)
        #expect(busy.ownerStatus == .unknown)
        keychain.store("keychain-token", service: "cursor-access-token")
        #expect(credentials(try await store.read())?.accessToken == "keychain-token")

        home.unlock(lock)
        #expect(credentials(try await store.read())?.accessToken == "database-token")
    }

    @Test func unusableDatabasesAreUnreadableButAllowTheKeychain() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        try home.directory.write(
            "not a database",
            to: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        let keychain = FakeKeychain()
        let store = CursorCredentialStore(home: home.url, keychain: keychain)

        #expect(failure(try await store.read()) == .credentialsUnreadable)
        keychain.store("keychain-token", service: "cursor-access-token")
        #expect(credentials(try await store.read())?.accessToken == "keychain-token")
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

    @Test func lockedKeychainIsUnknownNotSignedOut() async throws {
        let home = try CursorHome()
        defer { home.remove() }
        let keychain = FakeKeychain()
        keychain.failure = .unavailable
        let lookup = try await CursorCredentialStore(home: home.url, keychain: keychain).read()
        #expect(failure(lookup) == .keychainUnavailable)
        #expect(lookup.ownerStatus == .unknown)
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
