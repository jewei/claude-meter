import Foundation

/// A fixed instant for tests: 2026-10-04T12:00:00Z.
public let referenceDate = Date(timeIntervalSince1970: 1_791_201_600)

extension Date {
    /// `referenceDate` moved by `seconds`.
    public static func reference(_ seconds: TimeInterval = 0) -> Date {
        referenceDate.addingTimeInterval(seconds)
    }
}

extension TimeInterval {
    public static func minutes(_ value: Double) -> TimeInterval { value * 60 }
    public static func hours(_ value: Double) -> TimeInterval { value * 3_600 }
    public static func days(_ value: Double) -> TimeInterval { value * 86_400 }
}

extension Calendar {
    /// A Gregorian calendar fixed to one time zone, so day boundaries do not depend on the host.
    public static func fixed(_ identifier: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .gmt
        return calendar
    }
}
