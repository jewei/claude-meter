import Foundation

/// Splits a byte stream into newline-terminated lines, and bounds the line length and the
/// bytes that were delivered but not consumed yet.
///
/// The backlog counts each line with its newline, so a stream of empty lines fills it too.
struct LineBuffer: Sendable {
    let maxLineBytes: Int
    let maxBacklogBytes: Int
    /// Bytes after the last newline: the start of the next line.
    private var pending = Data()
    /// Delivered lines that were not consumed yet, newlines included.
    private(set) var backlogBytes = 0

    init(maxLineBytes: Int, maxBacklogBytes: Int) {
        self.maxLineBytes = maxLineBytes
        self.maxBacklogBytes = maxBacklogBytes
    }

    /// The complete lines that `chunk` ends, without their newlines, or the limit that the
    /// stream broke. After a failure, the stream is not used again.
    mutating func receive(_ chunk: Data) -> Result<[Data], LineProcess.ProcessError> {
        // `pending` holds no newline, so the search starts at the new bytes.
        let searched = pending.count
        pending.append(chunk)
        var lines: [Data] = []
        var lineStart = pending.startIndex
        var searchStart = pending.index(pending.startIndex, offsetBy: searched)
        // A moving index, and one removal at the end: a chunk of many short lines costs one
        // copy, not one copy of the rest of the buffer for each line.
        while let newline = pending[searchStart...].firstIndex(of: 0x0A) {
            let line = pending[lineStart..<newline]
            guard line.count <= maxLineBytes else {
                return .failure(.lineTooLong(limit: maxLineBytes))
            }
            backlogBytes += line.count + 1
            guard backlogBytes <= maxBacklogBytes else {
                return .failure(.backlogTooLarge(limit: maxBacklogBytes))
            }
            lines.append(Data(line))
            lineStart = pending.index(after: newline)
            searchStart = lineStart
        }
        pending.removeSubrange(pending.startIndex..<lineStart)
        guard pending.count <= maxLineBytes else {
            return .failure(.lineTooLong(limit: maxLineBytes))
        }
        return .success(lines)
    }

    /// Frees the backlog of a line that ``receive(_:)`` delivered.
    mutating func consume(_ line: Data) {
        backlogBytes = max(0, backlogBytes - (line.count + 1))
    }
}
