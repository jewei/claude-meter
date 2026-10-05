import Foundation

/// Selects the files that a scan reads.
public enum HistoryFileMatch: Equatable, Sendable {
    /// Every file with this extension, such as `jsonl`.
    case fileExtension(String)
    /// Every file with exactly this name, such as `updates.jsonl`.
    case fileName(String)

    func matches(_ name: String) -> Bool {
        switch self {
        case .fileExtension(let suffix):
            name.hasSuffix(".\(suffix)") && name.count > suffix.count + 1
        case .fileName(let fileName): name == fileName
        }
    }
}
