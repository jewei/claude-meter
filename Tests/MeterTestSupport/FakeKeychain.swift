import Foundation
import MeterPlatform

/// An in-memory Keychain. Set `failure` to make every call throw.
public final class FakeKeychain: Keychain {
    public struct Entry: Sendable {
        public var password: Data
        public var modifiedAt: Date?
    }

    private struct Key: Hashable, Sendable {
        let service: String
        let account: String
    }

    private let entries = Locked<[Key: Entry]>([:])
    private let injectedFailure = Locked<KeychainError?>(nil)
    private let reads = Locked<[String]>([])

    public init() {}

    /// The error that every call throws, or nil for normal behavior.
    public var failure: KeychainError? {
        get { injectedFailure.value }
        set { injectedFailure.withLock { $0 = newValue } }
    }

    /// Services whose secrets were read, in order.
    public var readServices: [String] { reads.value }

    public func store(
        _ password: String, service: String, account: String = "user", modifiedAt: Date? = nil
    ) {
        entries.withLock {
            $0[Key(service: service, account: account)] = Entry(
                password: Data(password.utf8), modifiedAt: modifiedAt)
        }
    }

    public func storedPassword(service: String, account: String) -> String? {
        entries.value[Key(service: service, account: account)].map {
            String(decoding: $0.password, as: UTF8.self)
        }
    }

    /// With `account: nil`, the item with the first account in sorted order wins, so a test
    /// with two accounts for one service gets the same item on every run.
    public func password(service: String, account: String?) throws(KeychainError) -> Data? {
        if let failure { throw failure }
        reads.withLock { $0.append(service) }
        let matches = entries.value.filter { key, _ in
            key.service == service && (account == nil || key.account == account)
        }
        return matches.min { $0.key.account < $1.key.account }?.value.password
    }

    public func items(
        servicePrefix: String, account: String?
    ) throws(KeychainError) -> [KeychainItem] {
        if let failure { throw failure }
        return entries.value.compactMap { key, entry in
            guard key.service.hasPrefix(servicePrefix), account == nil || key.account == account
            else { return nil }
            return KeychainItem(
                service: key.service, account: key.account, modifiedAt: entry.modifiedAt)
        }.sorted { $0.service < $1.service }
    }

    public func setPassword(
        _ password: Data, service: String, account: String
    ) throws(KeychainError) {
        if let failure { throw failure }
        entries.withLock {
            $0[Key(service: service, account: account)] = Entry(
                password: password, modifiedAt: Date())
        }
    }

    public func deletePassword(service: String, account: String) throws(KeychainError) {
        if let failure { throw failure }
        _ = entries.withLock { $0.removeValue(forKey: Key(service: service, account: account)) }
    }
}
