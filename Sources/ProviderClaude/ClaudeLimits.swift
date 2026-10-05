import Foundation

/// Time limits of Claude work. Tests shorten them.
struct ClaudeLimits: Sendable {
    /// Listing the config dirs.
    var discovery: Duration = .seconds(5)
    /// One whole refresh, all accounts included. In automatic mode, accounts that have not
    /// started when it ends keep their previous value, and finished accounts are kept.
    var refresh: Duration = .seconds(60)
    /// One account in automatic mode: credential, identity, one request, and the second read.
    /// Each HTTP request also has its own 15 s limit.
    var account: Duration = .seconds(20)
    /// One Keychain or file read.
    var localRead: Duration = .seconds(5)
    /// One write of the manual Keychain item.
    var keychainWrite: Duration = .seconds(5)

    /// The deadline around a whole automatic refresh. The work inside is bounded already, so
    /// this only stops a defect from holding the refresh forever.
    var safetyNet: Duration { refresh + localRead }
}
