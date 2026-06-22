import Foundation

enum ANSIStripper {
    static func strip(_ text: String) -> String {
        // Regex literals are compile-time constants — constructing inline avoids Swift 6 global Sendable check
        var result = text
        // CSI sequences (ESC [ … letter)
        result = result.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
        // Single-byte CSI (C1 control)
        result = result.replacing(/\u{9B}[0-9;]*[A-Za-z]/, with: "")
        // OSC sequences (ESC ] … BEL or ST)
        result = result.replacing(/\u{1B}\][^\u{07}\n]*(?:\u{07}|\u{1B}\\)/, with: "")
        return result
    }
}
