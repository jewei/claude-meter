import Foundation

/// Proof that a reading belongs to the login that is signed in now.
///
/// Providers compute an owner from local credentials. A reading survives a failed refresh only
/// while its owner still matches. Both cases hold a SHA-256 hex digest, never the raw value.
public enum AccountOwner: Codable, Hashable, Sendable {
    /// Derived from stable account identifiers, such as user and organization IDs.
    /// Survives token renewal and can be stored on disk.
    case identity(String)
    /// Derived from the credential itself because no identity is known. Changes on token
    /// renewal and never leaves memory.
    case credential(String)

    public var isPersistable: Bool {
        if case .identity = self { return true }
        return false
    }
}
