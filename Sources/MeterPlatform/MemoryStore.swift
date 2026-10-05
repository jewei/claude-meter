import Foundation

/// A store that keeps values in memory only, for tests and previews.
public final class MemoryStore: KeyValueStore {
    private let values = Locked<[String: Data]>([:])

    public init(_ values: [String: Data] = [:]) {
        self.values.withLock { $0 = values }
    }

    public func data(forKey key: String) -> Data? {
        values.value[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        values.withLock { $0[key] = data }
    }
}
