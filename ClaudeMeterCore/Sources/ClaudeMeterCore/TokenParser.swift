import Foundation

enum TokenParser {
    /// Parses token count shorthands: "8.4k" → 8400, "22.6m" → 22_600_000, "1.3b" → 1_300_000_000
    static func parseCount(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let multipliers: [(suffix: String, factor: Double)] = [
            ("b", 1_000_000_000),
            ("m", 1_000_000),
            ("k", 1_000),
        ]
        for (suffix, factor) in multipliers {
            if s.hasSuffix(suffix), let n = Double(s.dropLast()) {
                return Int((n * factor).rounded())
            }
        }
        return Int(s)
    }

    /// Parses "$6.89" or "6.89" as a Double.
    static func parseCost(_ raw: String) -> Double? {
        Double(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: ""))
    }
}
