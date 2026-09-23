import Foundation

/// Splits newline-delimited process output without retaining an unbounded
/// partial line. Overflow is terminal because truncated JSON is not trustworthy.
final class BoundedProcessLineBuffer: @unchecked Sendable {
    struct AppendResult: Sendable {
        let lines: [Data]
        let exceededLimit: Bool
    }

    private let lock = NSLock()
    private let maxBytes: Int
    private var buffer = Data()

    init(maxBytes: Int = 1 * 1024 * 1024) {
        self.maxBytes = max(0, maxBytes)
    }

    func appendAndDrainLines(_ chunk: Data) -> AppendResult {
        lock.withLock {
            var lines: [Data] = []
            var segmentStart = chunk.startIndex
            while let newline = chunk[segmentStart...].firstIndex(of: 0x0A) {
                let segment = chunk[segmentStart..<newline]
                guard segment.count <= maxBytes - buffer.count else {
                    buffer.removeAll(keepingCapacity: false)
                    return AppendResult(lines: [], exceededLimit: true)
                }
                buffer.append(segment)
                if !buffer.isEmpty { lines.append(buffer) }
                buffer.removeAll(keepingCapacity: true)
                segmentStart = chunk.index(after: newline)
            }

            let tail = chunk[segmentStart...]
            guard tail.count <= maxBytes - buffer.count else {
                buffer.removeAll(keepingCapacity: false)
                return AppendResult(lines: [], exceededLimit: true)
            }
            buffer.append(contentsOf: tail)
            return AppendResult(lines: lines, exceededLimit: false)
        }
    }
}
