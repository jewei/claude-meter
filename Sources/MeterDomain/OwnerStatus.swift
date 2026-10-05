import Foundation

/// What a provider knows about the current login of one account, for retention checks.
public enum OwnerStatus: Hashable, Sendable {
    case signedIn(AccountOwner)
    /// The credential is gone: the user signed out.
    case signedOut
    /// The credential could not be read right now, for example while the Keychain is locked.
    case unknown

    /// The single ownership rule: a value of `owner` may stay while that owner is signed in.
    /// A temporary read failure proves nothing, so `unknown` keeps it. A value without an
    /// owner belongs to no login, so only `unknown` keeps it.
    public func admits(_ owner: AccountOwner?) -> Bool {
        switch self {
        case .unknown: true
        case .signedOut: false
        case .signedIn(let current): owner == current
        }
    }
}
