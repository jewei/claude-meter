import Foundation

/// Small durable values, such as settings and a rate-limit deadline.
public protocol KeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    /// Stores `data`, or removes the key when `data` is nil.
    func set(_ data: Data?, forKey key: String)
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
