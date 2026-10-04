import Foundation

/// A generic-password Keychain item, described by its attributes only.
public struct KeychainItem: Hashable, Sendable {
    public let service: String
    public let account: String?
    public let modifiedAt: Date?

    public init(service: String, account: String?, modifiedAt: Date?) {
        self.service = service
        self.account = account
        self.modifiedAt = modifiedAt
    }
}

public enum KeychainError: Error, Equatable, LocalizedError, Sendable {
    /// The Keychain is locked or would need to show a prompt. Try again later.
    case unavailable
    /// The Keychain refused access to the item (`errSecAuthFailed`).
    case denied
    case failure(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The Keychain is locked or unavailable."
        case .denied: "The Keychain denied access to the credential."
        case .failure(let status): "The Keychain returned error \(status)."
        }
    }
}

/// Generic-password access without any user interface.
///
/// Inject a fake in tests. ``SystemKeychain`` refuses every call inside a test process, so a
/// test can never read real credentials by mistake.
public protocol Keychain: Sendable {
    /// The secret of one item, or nil when the item does not exist.
    func password(service: String, account: String?) throws(KeychainError) -> Data?
    /// Attributes of every item whose service starts with `servicePrefix`. Reads no secrets.
    func items(servicePrefix: String, account: String?) throws(KeychainError) -> [KeychainItem]
    /// Creates or replaces an item that this app owns.
    func setPassword(_ password: Data, service: String, account: String) throws(KeychainError)
    /// Deletes an item that this app owns. Deleting a missing item succeeds.
    func deletePassword(service: String, account: String) throws(KeychainError)
}
