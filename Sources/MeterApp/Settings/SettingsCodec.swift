import Foundation
import MeterPlatform

/// Reads and writes ``Settings`` as JSON that survives schema changes.
///
/// Decoding overlays the stored JSON on the JSON of the defaults, so a missing property takes
/// its default and an unknown property is ignored. A stored group that no longer decodes is
/// dropped alone, so one bad value never resets every preference.
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
        for key in stored.keys.sorted() {
            let candidate = merging([key: stored[key] as Any], over: accepted)
            if decode(candidate) != nil {
                accepted = candidate
            } else {
                Log(.app).warning("Ignored the unreadable setting group \(key).")
            }
        }
        return decode(accepted) ?? Settings()
    }

    private static func decode(_ object: [String: Any]) -> Settings? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder.meter.decode(Settings.self, from: data)
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
