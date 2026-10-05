import Foundation

/// Why one history file could not be read in this scan.
enum FileReadError: Error, Equatable, Sendable {
    /// The scan byte budget is used up. The file keeps its cursor and continues later.
    case budget
    /// The file was rewritten or replaced while it was read. The previous cursor stays.
    case changed
    case missing
    case notRegularFile
    case unreadable(errno: Int32)
}
