import Darwin
import Foundation

/// The read position in one append-only JSONL file and the records parsed before it.
///
/// A cursor resumes at its saved offset only when the file is the same file, did not shrink,
/// and still has the same first bytes and the same bytes before the offset. Otherwise the file
/// is parsed again from the start. This assumes that history files only grow by appends.
struct FileCursor<Parser: HistoryFileParser>: Sendable {
    /// What one read did. Bytes count against the scan budget even when the read failed.
    struct Progress: Sendable {
        enum Outcome: Sendable {
            /// The file did not change since the cursor was saved.
            case unchanged
            case read(FileCursor)
            case failed(FileReadError)
        }

        var outcome: Outcome
        var bytesRead = 0
        var parsedLines = 0
        /// The byte allowance ran out before the end of the file, so a read in the same history
        /// read can go on at once (``HistoryScanner/catchUp(_:since:)``).
        var reachedAllowance = false
    }

    /// The stamp of the file when it was last read.
    private(set) var stamp: FileStamp
    /// The end of the last complete line, or of the consumed bytes of a skipped long line.
    private(set) var offset: Int64 = 0
    private(set) var parser = Parser()
    /// A skipped long line could hold a record: it has the parser's
    /// ``HistoryFileParser/recordMarker``, or the parser has none.
    private(set) var skippedRecordLine = false
    private(set) var reachedRecordLimit = false
    private var head = Data()
    private var boundary = Data()
    private var isSkippingLine = false
    /// The last bytes of the skipped line so far, so a marker split between two reads is found.
    private var skippedTail = Data()

    init(stamp: FileStamp) {
        self.stamp = stamp
    }

    /// True when every byte of the file was parsed and no line or record was left out. An
    /// incomplete final line is read again later, so the file is not complete meanwhile. A
    /// skipped long line leaves out a record only when it could hold one.
    var isComplete: Bool {
        offset == stamp.size && !skippedRecordLine && !reachedRecordLimit && !isSkippingLine
    }

    /// Reads the lines that were appended to the file at `path` after `previous`.
    ///
    /// `available` is what is left of the scan byte budget. This call blocks; run it inside
    /// ``BlockingIO``. It throws only `CancellationError`.
    static func read(
        _ path: String, after previous: FileCursor?, available: Int, limits: HistoryLimits,
        cancellation: BlockingIO.Cancellation
    ) throws -> Progress {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let error: FileReadError =
                switch errno {
                case ENOENT, ENOTDIR: .missing
                case ELOOP: .notRegularFile
                default: .unreadable(errno: errno)
                }
            return Progress(outcome: .failed(error))
        }
        defer { close(descriptor) }
        var reader = CountingReader(descriptor: descriptor)
        var lines = 0
        var reachedAllowance = false
        do {
            let outcome = try advance(
                previous, reader: &reader, lines: &lines, reachedAllowance: &reachedAllowance,
                available: available, limits: limits, cancellation: cancellation)
            return Progress(
                outcome: outcome, bytesRead: reader.bytesRead, parsedLines: lines,
                reachedAllowance: reachedAllowance)
        } catch let error as FileReadError {
            return Progress(
                outcome: .failed(error), bytesRead: reader.bytesRead, parsedLines: lines)
        }
    }

    private static func advance(
        _ previous: FileCursor?, reader: inout CountingReader, lines: inout Int,
        reachedAllowance: inout Bool, available: Int, limits: HistoryLimits,
        cancellation: BlockingIO.Cancellation
    ) throws -> Progress.Outcome {
        let stamp = try FileStamp(descriptor: reader.descriptor)
        // Only a saved cursor can be unchanged. A new empty file needs a cursor too, or it
        // would read as never read.
        if let previous, previous.stamp == stamp, previous.offset == stamp.size {
            return .unchanged
        }
        var cursor = previous ?? FileCursor(stamp: stamp)
        let reserve = cursor.head.count + cursor.boundary.count + HistoryLimits.reserveBytes
        guard available >= reserve else { throw FileReadError.budget }

        if try !cursor.canResume(at: stamp, reader: &reader) {
            cursor = FileCursor(stamp: stamp)
        }
        cursor.stamp = stamp
        let allowance = min(
            limits.fileBytes, max(0, available - reader.bytesRead - HistoryLimits.reserveBytes))
        (lines, reachedAllowance) = try cursor.parse(
            &reader, allowance: allowance, limits: limits, cancellation: cancellation)
        try cursor.saveSamples(&reader)

        // An active session appends while it is read; that is fine, the next scan reads the
        // new lines. A file that shrank, or changed without growing, was rewritten.
        let after = try FileStamp(descriptor: reader.descriptor)
        guard after.isSameFile(as: stamp), after.size > stamp.size || after == stamp else {
            throw FileReadError.changed
        }
        return .read(cursor)
    }

    private func canResume(at stamp: FileStamp, reader: inout CountingReader) throws -> Bool {
        guard stamp.isSameFile(as: self.stamp), stamp.size >= self.stamp.size else { return false }
        if stamp.size == self.stamp.size { return stamp == self.stamp }
        guard offset > 0 else { return true }
        let head = try reader.read(at: 0, count: self.head.count)
        let boundary = try reader.read(
            at: offset - Int64(self.boundary.count), count: self.boundary.count)
        return head == self.head && boundary == self.boundary
    }

    /// Parses lines until the end of the file, the allowance, or the record limit. Returns the
    /// parsed lines, and whether the allowance ran out before the end of the file.
    private mutating func parse(
        _ reader: inout CountingReader, allowance: Int, limits: HistoryLimits,
        cancellation: BlockingIO.Cancellation
    ) throws -> (lines: Int, reachedAllowance: Bool) {
        let decoder = JSONDecoder()
        var position = offset
        var remaining = allowance
        var line = Data()
        var lines = 0
        while position < stamp.size, remaining > 0, !reachedRecordLimit {
            if cancellation.isCancelled { throw CancellationError() }
            let wanted = min(HistoryLimits.chunkBytes, remaining, Int(stamp.size - position))
            let chunk = try reader.read(at: position, count: wanted)
            guard !chunk.isEmpty else { throw FileReadError.changed }
            remaining -= chunk.count
            var start = chunk.startIndex
            while start < chunk.endIndex, !reachedRecordLimit {
                guard let newline = Self.newline(in: chunk, from: start) else {
                    collect(chunk[start...], into: &line, limit: limits.lineBytes)
                    break
                }
                collect(chunk[start..<newline], into: &line, limit: limits.lineBytes)
                if !isSkippingLine, !line.isEmpty {
                    parser.append(line, offset: offset, decoder: decoder)
                    lines += 1
                }
                line.removeAll(keepingCapacity: true)
                isSkippingLine = false
                skippedTail.removeAll()
                offset = position + Int64(newline - chunk.startIndex) + 1
                start = newline + 1
                if parser.recordCount >= limits.fileRecords { reachedRecordLimit = true }
            }
            position += Int64(chunk.count)
            // The consumed part of a long line is never read again.
            if isSkippingLine { offset = position }
        }
        return (lines, position < stamp.size && remaining <= 0 && !reachedRecordLimit)
    }

    /// Adds bytes to the current line, or starts skipping it when it grows past `limit`.
    private mutating func collect(_ bytes: Data, into line: inout Data, limit: Int) {
        if isSkippingLine {
            noteSkipped(bytes)
        } else if line.count + bytes.count <= limit {
            line.append(bytes)
        } else {
            isSkippingLine = true
            noteSkipped(line)
            noteSkipped(bytes)
            line.removeAll()
        }
    }

    /// Looks for the parser's record marker in the skipped bytes. The search joins
    /// ``skippedTail``, so a marker split between two reads is found.
    private mutating func noteSkipped(_ bytes: Data) {
        guard !skippedRecordLine else { return }
        guard let marker = Parser.recordMarker, !marker.isEmpty else {
            skippedRecordLine = true
            return
        }
        let searched = skippedTail + bytes
        if searched.range(of: marker) != nil {
            skippedRecordLine = true
        } else {
            skippedTail = Data(searched.suffix(marker.count - 1))
        }
    }

    private mutating func saveSamples(_ reader: inout CountingReader) throws {
        let count = Int(min(Int64(HistoryLimits.sampleBytes), offset))
        head = try reader.read(at: 0, count: count)
        boundary = try reader.read(at: offset - Int64(count), count: count)
    }

    private static func newline(in chunk: Data, from start: Int) -> Int? {
        chunk.withUnsafeBytes { buffer -> Int? in
            let relative = start - chunk.startIndex
            guard let base = buffer.baseAddress, relative < buffer.count,
                let found = memchr(base + relative, 0x0A, buffer.count - relative)
            else { return nil }
            return chunk.startIndex + base.distance(to: UnsafeRawPointer(found))
        }
    }
}

/// Reads byte ranges of an open file and counts every byte against the scan budget.
private struct CountingReader {
    let descriptor: Int32
    var bytesRead = 0

    mutating func read(at offset: Int64, count: Int) throws(FileReadError) -> Data {
        guard count > 0 else { return Data() }
        do {
            let data = try LocalFile.read(descriptor, from: offset, count: count)
            bytesRead += data.count
            return data
        } catch {
            if case .unreadable(let code) = error { throw .unreadable(errno: code) }
            throw .unreadable(errno: EIO)
        }
    }
}
