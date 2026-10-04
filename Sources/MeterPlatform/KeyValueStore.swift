import Foundation

/// Small durable values, such as settings and a rate-limit deadline.
public protocol KeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    /// Stores `data`, or removes the key when `data` is nil.
    func set(_ data: Data?, forKey key: String)
}

/// A `UserDefaults` domain. The app uses the standard domain; previews use a named suite.
public final class DefaultsStore: KeyValueStore, @unchecked Sendable {
    // UserDefaults is thread-safe.
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func set(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

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

extension KeyValueStore {
    /// Decodes a JSON value, or returns nil when the key is missing or the value is invalid.
    public func value<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        data(forKey: key).flatMap { try? JSONDecoder.meter.decode(type, from: $0) }
    }

    /// Stores a value as JSON, or removes the key when `value` is nil.
    public func setValue<Value: Encodable>(_ value: Value?, forKey key: String) {
        set(value.flatMap { try? JSONEncoder.meter.encode($0) }, forKey: key)
    }
}

extension JSONEncoder {
    /// The encoder for every file and value that the app writes: ISO-8601 dates and sorted keys.
    public static var meter: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    /// The decoder that matches ``JSONEncoder/meter``.
    public static var meter: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
