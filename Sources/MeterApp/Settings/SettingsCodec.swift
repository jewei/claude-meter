import Foundation
import MeterPlatform

/// Reads and writes ``Settings`` as JSON that survives schema changes.
///
/// Decoding overlays the stored JSON on the JSON of the defaults, so a missing property takes
/// its default and an unknown property is ignored. When the stored value does not decode, each
/// stored value is accepted on its own, down to single object keys and array elements, so one
/// foreign value (an unknown card or provider from a newer version, a wrong type) drops only
/// itself and never resets its group.
public enum SettingsCodec {
    public static func encode(_ settings: Settings) -> Data {
        // Encoding plain value types cannot fail.
        (try? JSONEncoder.meter.encode(settings)) ?? Data()
    }

    public static func decode(_ data: Data?) -> Settings {
        guard let data,
            let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let defaults = try? JSONSerialization.jsonObject(with: encode(Settings()))
                as? [String: Any]
        else { return Settings() }

        if let settings = decode(merging(stored, over: defaults)) { return settings }

        var accepted = defaults
        accept(stored, at: [], into: &accepted)
        return decode(accepted) ?? Settings()
    }

    private static func decode(_ object: [String: Any]) -> Settings? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder.meter.decode(Settings.self, from: data)
    }

    /// Accepts each key of `stored` (found at `path`) that still decodes. A key that does not
    /// decode is tried again part by part: an object key by key, an array element by element.
    private static func accept(
        _ stored: [String: Any], at path: [String], into accepted: inout [String: Any]
    ) {
        for key in stored.keys.sorted() {
            guard let value = stored[key] else { continue }
            let keyPath = path + [key]
            let current = Self.value(at: keyPath, in: accepted)
            let merged: Any =
                if let object = value as? [String: Any], let base = current as? [String: Any] {
                    merging(object, over: base)
                } else {
                    value
                }
            if let candidate = setting(merged, at: keyPath, in: accepted), decode(candidate) != nil
            {
                accepted = candidate
            } else if let object = value as? [String: Any],
                current == nil || current is [String: Any]
            {
                accept(object, at: keyPath, into: &accepted)
            } else if let array = value as? [Any] {
                acceptElements(of: array, at: keyPath, into: &accepted)
            } else {
                Log(.app).warning(
                    "Ignored the unreadable setting \(keyPath.joined(separator: ".")).")
            }
        }
    }

    /// Keeps the elements of a stored array that decode, in order, and drops the others.
    private static func acceptElements(
        of array: [Any], at path: [String], into accepted: inout [String: Any]
    ) {
        var kept: [Any] = []
        for element in array {
            if let candidate = setting(kept + [element], at: path, in: accepted),
                decode(candidate) != nil
            {
                kept.append(element)
            } else {
                Log(.app).warning("Ignored an unreadable value in \(path.joined(separator: ".")).")
            }
        }
        if let candidate = setting(kept, at: path, in: accepted), decode(candidate) != nil {
            accepted = candidate
        }
    }

    private static func value(at path: [String], in object: [String: Any]) -> Any? {
        guard let first = path.first else { return object }
        guard path.count > 1 else { return object[first] }
        guard let nested = object[first] as? [String: Any] else { return nil }
        return value(at: Array(path.dropFirst()), in: nested)
    }

    /// `object` with `newValue` at `path`, creating objects on the way. Nil when the path runs
    /// through a value that is not an object.
    private static func setting(_ newValue: Any, at path: [String], in object: [String: Any])
        -> [String: Any]?
    {
        guard let first = path.first else { return nil }
        var result = object
        guard path.count > 1 else {
            result[first] = newValue
            return result
        }
        let nested = object[first] ?? [String: Any]()
        guard let nested = nested as? [String: Any],
            let updated = setting(newValue, at: Array(path.dropFirst()), in: nested)
        else { return nil }
        result[first] = updated
        return result
    }

    /// `overlay` wins. Nested objects merge key by key; every other value replaces.
    static func merging(_ overlay: [String: Any], over base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let nested = value as? [String: Any], let baseNested = base[key] as? [String: Any] {
                result[key] = merging(nested, over: baseNested)
            } else {
                result[key] = value
            }
        }
        return result
    }
}
