import Foundation

/// A token history read that cannot start.
public enum HistoryError: Error, Equatable, LocalizedError, Sendable {
    /// The current date is outside the range that the app accepts.
    case invalidDate

    public var errorDescription: String? {
        switch self {
        case .invalidDate: "The date of this Mac is not valid. Check the date and time settings."
        }
    }
}
