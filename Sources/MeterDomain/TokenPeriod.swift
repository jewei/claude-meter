import Foundation

/// A calendar period for token totals.
public enum TokenPeriod: CaseIterable, Sendable {
    case today
    case yesterday
    /// Today and the previous six local calendar days.
    case lastSevenDays

    public var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastSevenDays: "Last 7 Days"
        }
    }

    /// The local-day interval that contains the period at `now`.
    public func interval(at now: Date, calendar: Calendar) -> DateInterval? {
        guard DateBounds.contains(now) else { return nil }
        let today = calendar.startOfDay(for: now)
        let (startOffset, endOffset) =
            switch self {
            case .today: (0, 1)
            case .yesterday: (-1, 0)
            case .lastSevenDays: (-6, 1)
            }
        guard let start = calendar.date(byAdding: .day, value: startOffset, to: today),
            let end = calendar.date(byAdding: .day, value: endOffset, to: today),
            DateBounds.contains(start), DateBounds.contains(end)
        else { return nil }
        return DateInterval(start: start, end: end)
    }
}
