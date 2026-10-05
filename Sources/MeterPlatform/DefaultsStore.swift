import Foundation

/// A `UserDefaults` domain. The app uses the standard domain; previews use a named suite.
///
/// Inside a test process, `DefaultsStore()` keeps values in memory only, so a test can never
/// read or change the settings of an installed copy. A domain passed explicitly is used in any
/// process.
public final class DefaultsStore: KeyValueStore, @unchecked Sendable {
    // No lock: `UserDefaults` serializes access itself (Apple documents it as thread-safe),
    // and `defaults` is never reassigned. The SDK does not mark it `Sendable`. `volatile` is
    // a `MemoryStore`, which has its own lock.
    private let defaults: UserDefaults?
    private let volatile = MemoryStore()

    /// Uses `defaults`, or the standard domain when it is nil. In a test process, nil keeps
    /// the values in memory instead.
    public init(_ defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? (TestProcess.isRunning ? nil : .standard)
    }

    /// False when the values stay in memory, as in a test process.
    var isPersistent: Bool { defaults != nil }

    public func data(forKey key: String) -> Data? {
        guard let defaults else { return volatile.data(forKey: key) }
        return defaults.data(forKey: key)
    }

    public func set(_ data: Data?, forKey key: String) {
        guard let defaults else { return volatile.set(data, forKey: key) }
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
