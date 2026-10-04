import Foundation

/// Small durable values, such as settings and a rate-limit deadline.
public protocol KeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    /// Stores `data`, or removes the key when `data` is nil.
    func set(_ data: Data?, forKey key: String)
}

/// A `UserDefaults` domain. The app uses the standard domain; previews use a named suite.
public final class DefaultsStore: KeyValueStore, @unchecked Sendable {
    // No lock: `UserDefaults` serializes access itself (Apple documents it as thread-safe),
    // and `defaults` is never reassigned. The SDK does not mark it `Sendable`.
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
    /// The encoder for every file and value that the app writes: ISO-8601 dates with
    /// milliseconds, such as `2026-10-04T12:00:00.750Z`, and sorted keys.
    ///
    /// Whole seconds are not enough: a deadline read back after a relaunch must not end up to
    /// a second early.
    public static var meter: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(MeterDateFormat.withMilliseconds))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    /// The decoder that matches ``JSONEncoder/meter``. It also reads ISO-8601 dates without
    /// fractional seconds, as earlier versions wrote them.
    public static var meter: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: MeterDateFormat.withMilliseconds) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected an ISO-8601 date.")
        }
        return decoder
    }
}

private enum MeterDateFormat {
    static let withMilliseconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
