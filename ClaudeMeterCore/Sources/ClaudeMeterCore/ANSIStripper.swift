import Foundation

enum ANSIStripper {
    static func strip(_ text: String) -> String {
        // Regex literal is a compile-time constant — constructing inline avoids Swift 6 global Sendable check
        text.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
    }
}
