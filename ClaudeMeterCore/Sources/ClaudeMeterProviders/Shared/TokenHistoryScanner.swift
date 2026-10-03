import ClaudeMeterCore
import Darwin
import Foundation

/// A bounded, memory-only parse cache. All mutable state belongs to this serial queue.
final class TokenHistoryScanner: @unchecked Sendable {
    struct Limits: Sendable {
        var scanBytes = 64 * 1024 * 1024
        var fileBytes = 8 * 1024 * 1024
        var lineBytes = 1024 * 1024
        var files = 2048
        var fileRecords = 20_000
        var records = 100_000
        var directoryEntries = 20_000
    }

    struct Work: Equatable, Sendable {
        var bytesRead = 0
        var parsedLines = 0
        var cacheHits = 0
    }

    private struct Stamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let seconds: Int64
        let nanos: Int64
        let changeSeconds: Int64
        let changeNanos: Int64

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            size = status.st_size
            seconds = Int64(status.st_mtimespec.tv_sec)
            nanos = Int64(status.st_mtimespec.tv_nsec)
            changeSeconds = Int64(status.st_ctimespec.tv_sec)
            changeNanos = Int64(status.st_ctimespec.tv_nsec)
        }

        func sameFile(as other: Self) -> Bool { device == other.device && inode == other.inode }
    }

    private struct FileState {
        var stamp: Stamp
        var offset: Int64 = 0
        var head = Data()
        var boundary = Data()
        var parser: TokenLogParser
        var skippingLine = false
        var recordLimitReached = false
    }

    private enum ScanError: Error { case byteBudget }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }

    private let provider: ProviderID
    private let limits: Limits
    private let queue = DispatchQueue(label: "com.jewei.claudemeter.token-history", qos: .utility)
    private var cache: [String: FileState] = [:]
    private var lastWork = Work()

    init(provider: ProviderID, limits: Limits = Limits()) {
        self.provider = provider
        self.limits = limits
    }

    func scan(roots: [URL], now: Date, calendar: Calendar = .current) async throws
        -> TokenUsageSnapshot
    {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let result = try self.scanOnQueue(
                            roots: roots, now: now, calendar: calendar, cancellation: cancellation)
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func work() async -> Work {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.lastWork) }
        }
    }

    private func scanOnQueue(
        roots: [URL], now: Date, calendar: Calendar, cancellation: Cancellation
    ) throws -> TokenUsageSnapshot {
        try cancellation.check()
        var accumulator = try TokenDayAccumulator(now: now, calendar: calendar)
        lastWork = Work()
        var candidates: [(url: URL, modified: Date)] = []
        var visited = Set<String>()
        var entries = 0
        for root in roots {
            try cancellation.check()
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            guard visited.insert(root.path).inserted else { continue }
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            var failed = false
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                    ],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in
                        failed = true
                        return false
                    })
            else {
                accumulator.isPartial = true
                continue
            }
            while let url = enumerator.nextObject() as? URL {
                try cancellation.check()
                entries += 1
                guard entries <= limits.directoryEntries, candidates.count < limits.files else {
                    accumulator.isPartial = true
                    break
                }
                let matches =
                    provider == .grok
                    ? url.lastPathComponent == "updates.jsonl" : url.pathExtension == "jsonl"
                guard matches else { continue }
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                ])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                    accumulator.isPartial = true
                    continue
                }
                let modified = values?.contentModificationDate ?? .distantFuture
                guard modified >= accumulator.start else { continue }
                candidates.append((url, modified))
            }
            accumulator.isPartial = accumulator.isPartial || failed
        }
        let urls = candidates.sorted {
            $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified
        }.map(\.url)
        let present = Set(urls.map(\.path))
        cache = cache.filter { present.contains($0.key) }
        var records = 0
        var identities = Set<String>()
        // Recent files get the first share of the scan budget.
        for url in urls {
            try cancellation.check()
            do {
                try read(url, cancellation: cancellation, identities: &identities)
            } catch is CancellationError {
                throw CancellationError()
            } catch ScanError.byteBudget {
                accumulator.isPartial = true
            } catch {
                accumulator.isPartial = true
                cache.removeValue(forKey: url.path)
            }
            if let state = cache[url.path] {
                records += state.parser.events.count + state.parser.codex.events.count
                if records > limits.records {
                    cache.removeValue(forKey: url.path)
                    accumulator.isPartial = true
                }
            }
        }
        var hasRecords = false
        var events: [String: TokenEvent] = [:]
        var sessions: [String: CodexTokenLog] = [:]
        for path in cache.keys.sorted() {
            try cancellation.check()
            guard let file = cache[path] else { continue }
            accumulator.isPartial =
                accumulator.isPartial || file.parser.isPartial
                || file.offset < file.stamp.size || file.recordLimitReached
            if provider == .codex {
                let parsed = file.parser.codex
                hasRecords = hasRecords || !parsed.events.isEmpty
                let key = parsed.sessionID ?? path
                if let old = sessions[key] {
                    if parsed.sameOwnership(as: old), parsed.events.starts(with: old.events) {
                        sessions[key] = parsed
                    } else if !parsed.sameOwnership(as: old)
                        || !old.events.starts(with: parsed.events)
                    {
                        accumulator.isPartial = true
                        if parsed.events.count > old.events.count { sessions[key] = parsed }
                    }
                } else {
                    sessions[key] = parsed
                }
            } else {
                hasRecords = hasRecords || file.parser.hasRecords
                for (key, event) in file.parser.events {
                    // A copied response may have an older streaming snapshot.
                    if let old = events[key],
                        old.date > event.date
                            || old.date == event.date && old.count >= event.count
                    {
                        continue
                    }
                    events[key] = event
                }
            }
        }
        for event in events.values { accumulator.add(event) }
        for session in sessions.values {
            let result = session.reconciled(parent: session.parentID.flatMap { sessions[$0] })
            accumulator.isPartial = accumulator.isPartial || result.partial
            for event in result.events { accumulator.add(event) }
        }
        try cancellation.check()
        return accumulator.snapshot(provider: provider, hasRecords: hasRecords)
    }

    private func read(
        _ url: URL, cancellation: Cancellation, identities: inout Set<String>
    ) throws {
        let fd = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw BoundedRegularFileReader.ReadError.openFailed(errno) }
        defer { Darwin.close(fd) }
        var status = stat()
        guard Darwin.fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_size >= 0
        else { throw BoundedRegularFileReader.ReadError.notRegularFile }
        let stamp = Stamp(status)
        guard identities.insert("\(stamp.device):\(stamp.inode)").inserted else {
            cache.removeValue(forKey: url.path)
            return
        }
        var state =
            cache[url.path] ?? FileState(stamp: stamp, parser: TokenLogParser(provider: provider))
        if state.stamp == stamp, state.offset == stamp.size {
            lastWork.cacheHits += 1
            return
        }
        guard limits.scanBytes - lastWork.bytesRead >= state.head.count + state.boundary.count + 512
        else {
            throw ScanError.byteBudget
        }
        if !state.stamp.sameFile(as: stamp) || stamp.size < state.stamp.size
            || stamp.size == state.stamp.size && state.stamp != stamp
        {
            state = FileState(stamp: stamp, parser: TokenLogParser(provider: provider))
        } else if state.offset > 0 {
            // Check the saved beginning and append boundary before using an offset.
            // Replaced, truncated, and rewritten boundaries start a new parse.
            let head = try bytes(fd, offset: 0, count: state.head.count)
            let boundary = try bytes(
                fd, offset: state.offset - Int64(state.boundary.count), count: state.boundary.count)
            if head != state.head || boundary != state.boundary {
                state = FileState(stamp: stamp, parser: TokenLogParser(provider: provider))
            }
        }
        state.stamp = stamp
        var position = state.offset
        var buffer = Data()
        let allowance = min(limits.fileBytes, max(0, limits.scanBytes - lastWork.bytesRead - 512))
        var remaining = allowance
        while position < stamp.size, remaining > 0, !state.recordLimitReached {
            try cancellation.check()
            let count = min(64 * 1024, remaining, Int(min(Int64(Int.max), stamp.size - position)))
            let chunk = try bytes(fd, offset: position, count: count)
            guard !chunk.isEmpty else { throw BoundedRegularFileReader.ReadError.fileChanged }
            remaining -= chunk.count
            for byte in chunk {
                position += 1
                if byte == 0x0A {
                    if !state.skippingLine, !buffer.isEmpty {
                        state.parser.append(buffer, identity: "\(url.path):\(state.offset)")
                        lastWork.parsedLines += 1
                    }
                    buffer.removeAll(keepingCapacity: true)
                    state.skippingLine = false
                    state.offset = position
                    if state.parser.events.count + state.parser.codex.events.count
                        >= limits.fileRecords
                    {
                        state.recordLimitReached = true
                        break
                    }
                } else if !state.skippingLine {
                    if buffer.count < limits.lineBytes {
                        buffer.append(byte)
                    } else {
                        buffer.removeAll(keepingCapacity: true)
                        state.skippingLine = true
                        state.parser.isPartial = true
                    }
                }
            }
            if state.skippingLine { state.offset = position }
        }
        state.head = try bytes(fd, offset: 0, count: Int(min(256, state.offset)))
        let boundarySize = Int(min(256, state.offset))
        state.boundary = try bytes(
            fd, offset: state.offset - Int64(boundarySize), count: boundarySize)
        var after = stat()
        guard Darwin.fstat(fd, &after) == 0, Stamp(after) == stamp else {
            throw BoundedRegularFileReader.ReadError.fileChanged
        }
        cache[url.path] = state
    }

    private func bytes(_ fd: Int32, offset: Int64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let amount = buffer.withUnsafeMutableBytes {
                Darwin.pread(
                    fd, $0.baseAddress!.advanced(by: received), count - received,
                    offset + Int64(received))
            }
            if amount > 0 {
                received += amount
            } else if amount == 0 {
                break
            } else if errno != EINTR {
                throw BoundedRegularFileReader.ReadError.readFailed(errno)
            }
        }
        lastWork.bytesRead += received
        return Data(buffer.prefix(received))
    }
}
