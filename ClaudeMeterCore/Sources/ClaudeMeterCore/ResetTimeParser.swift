import Foundation

enum ResetTimeParser {
    /// Parses the text after "Resets" in Claude CLI output.
    ///
    /// Supported formats (examples):
    ///   "2:50pm (Asia/Kuala_Lumpur)"
    ///   "3pm (Asia/Kuala_Lumpur)"
    ///   "Jun 27 at 3pm (Asia/Kuala_Lumpur)"
    ///   "June 27 at 3:00 PM (Asia/Kuala_Lumpur)"
    static func parse(_ raw: String, now: Date, fallbackTimeZone: TimeZone) -> Date? {
        let (timeStr, tz) = extractTimezone(from: raw, fallback: fallbackTimeZone)
        let trimmed = timeStr.trimmingCharacters(in: .whitespaces)

        return parseDateAndTime(trimmed, in: tz, now: now)
            ?? parseTimeOnly(trimmed, in: tz, now: now)
    }

    // MARK: - Timezone extraction

    private static func extractTimezone(from text: String, fallback: TimeZone) -> (String, TimeZone) {
        // Find the last "(IANA/Identifier)" in the string
        guard let openParen = text.lastIndex(of: "("),
              let closeParen = text.lastIndex(of: ")"),
              openParen < closeParen
        else {
            return (text, fallback)
        }
        let tzId = String(text[text.index(after: openParen)..<closeParen])
        let tz = TimeZone(identifier: tzId) ?? fallback
        let before = String(text[text.startIndex..<openParen]).trimmingCharacters(in: .whitespaces)
        return (before, tz)
    }

    // MARK: - Date + time ("Jun 27 at 3pm", "June 27 at 3:00 PM")

    private static func parseDateAndTime(_ text: String, in tz: TimeZone, now: Date) -> Date? {
        let formats = [
            "MMM d 'at' h:mma",
            "MMM d 'at' ha",
            "MMM d 'at' h:mm a",
            "MMMM d 'at' h:mma",
            "MMMM d 'at' ha",
            "MMMM d 'at' h:mm a",
        ]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let fmt = makeDateFormatter(tz: tz)
        for format in formats {
            fmt.dateFormat = format
            if let parsed = fmt.date(from: text) {
                return resolveYear(for: parsed, cal: cal, now: now)
            }
        }
        return nil
    }

    // MARK: - Time only ("2:50pm", "3pm", "3:00 PM")

    private static func parseTimeOnly(_ text: String, in tz: TimeZone, now: Date) -> Date? {
        let formats = ["h:mma", "ha", "h:mm a"]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let fmt = makeDateFormatter(tz: tz)
        for format in formats {
            fmt.dateFormat = format
            guard let parsed = fmt.date(from: text) else { continue }

            let parsedComps = cal.dateComponents([.hour, .minute], from: parsed)
            let nowComps = cal.dateComponents([.year, .month, .day], from: now)

            var comps = DateComponents()
            comps.year = nowComps.year
            comps.month = nowComps.month
            comps.day = nowComps.day
            comps.hour = parsedComps.hour
            comps.minute = parsedComps.minute
            comps.second = 0
            comps.timeZone = tz

            guard var date = cal.date(from: comps) else { continue }

            // Time is in the past today — roll to tomorrow
            if date <= now {
                date = cal.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return date
        }
        return nil
    }

    // MARK: - Year resolution

    /// DateFormatter yields year 2000 when no year is in the format string.
    /// Inject the current year, then push to next year if the result is in the past.
    private static func resolveYear(for date: Date, cal: Calendar, now: Date) -> Date {
        var comps = cal.dateComponents([.month, .day, .hour, .minute], from: date)
        comps.year = cal.component(.year, from: now)
        comps.second = 0
        comps.timeZone = cal.timeZone

        guard let candidate = cal.date(from: comps) else { return date }

        if candidate < now.addingTimeInterval(-86400) {
            comps.year = (comps.year ?? 0) + 1
            return cal.date(from: comps) ?? candidate
        }
        return candidate
    }

    // MARK: - Helpers

    private static func makeDateFormatter(tz: TimeZone) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = tz
        return fmt
    }
}
