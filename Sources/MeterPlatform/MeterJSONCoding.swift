import Foundation

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
