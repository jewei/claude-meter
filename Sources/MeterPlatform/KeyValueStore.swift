import Foundation

/// Small durable values, such as settings and a rate-limit deadline.
public protocol KeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    /// Stores `data`, or removes the key when `data` is nil.
    func set(_ data: Data?, forKey key: String)
}

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
    /// The encoder for every file and value that the app writes: ISO-8601 dates and sorted
    /// keys. A date with a fraction of a second keeps its milliseconds
    /// (`2026-10-04T12:00:00.750Z`); a whole second is written without a fraction
    /// (`2026-10-04T12:00:00Z`), as earlier versions wrote and read it.
    ///
    /// Whole seconds alone are not enough: a deadline read back after a relaunch must not end
    /// up to a second early.
    public static var meter: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let seconds = date.timeIntervalSince1970
            let text =
                seconds.rounded(.down) == seconds
                ? date.formatted(.iso8601) : date.formatted(MeterDateFormat.withMilliseconds)
            try container.encode(text)
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
