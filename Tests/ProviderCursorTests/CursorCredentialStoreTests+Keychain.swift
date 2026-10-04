import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCursor

/// When the Keychain is read, and what each Keychain outcome means.
extension CursorCredentialStoreTests {
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
