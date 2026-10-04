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
        var directoryEntries = 0
        var discoveredFiles = 0
        var cachedFiles = 0
        var cachedRecords = 0
    }

    private struct RootIdentity: Equatable {
        let url: URL
        let account: String
        let device: Int32
        let inode: UInt64
        let exists: Bool

        init(_ url: URL, account: String) {
            self.url = url
            self.account = account
            var status = stat()
            exists = url.path.withCString { Darwin.lstat($0, &status) } == 0
            device = status.st_dev
            inode = status.st_ino
        }
    }

    /// Queue-owned cursors keep a bounded scan from visiting the same prefix forever.
    /// Take one entry from each root in turn so a large root cannot starve later roots.
    private final class Discovery {
        let roots: [RootIdentity]
        var cursors: [FileManager.DirectoryEnumerator?]
        var started: Set<Int> = []
        var finished: Set<Int> = []
        var nextRoot = 0
        var files: [String: Date] = [:]
        var erroredRoots: Set<Int> = []
        var exceededFileLimit = false
        var hadErrors: Bool { !erroredRoots.isEmpty }
        var isComplete: Bool { finished.count == roots.count }

        init(roots: [RootIdentity]) {
            self.roots = roots
            self.cursors = Array(repeating: nil, count: roots.count)
        }

        func next(cancellation: Cancellation) throws -> (url: URL, root: Int)? {
            while !isComplete {
                try cancellation.check()
                let index = nextRoot
                nextRoot = (index + 1) % roots.count
                guard !finished.contains(index) else { continue }
                if started.insert(index).inserted {
                    guard roots[index].exists else {
                        finished.insert(index)
                        continue
                    }
                    cursors[index] = FileManager.default.enumerator(
                        at: roots[index].url,
                        includingPropertiesForKeys: [
                            .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                        ],
                        options: [.skipsHiddenFiles],
                        errorHandler: { [weak self] _, _ in
                            self?.erroredRoots.insert(index)
                            return false
                        })
                    if cursors[index] == nil { erroredRoots.insert(index) }
                }
                if let url = cursors[index]?.nextObject() as? URL { return (url, index) }
                cursors[index] = nil
                finished.insert(index)
            }
            return nil
        }
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
    private var discoveryRoots: [RootIdentity] = []
    private var discoveryStart: Date?
    private var discovery: Discovery?
    private var inventory: [String: Date] = [:]
    /// The root that found each file. Enumerated paths can differ from the root path, as
    /// `/private/var` does from `/var`, so a path prefix cannot identify the owner.
    private var owners: [String: Int] = [:]

    init(provider: ProviderID, limits: Limits = Limits()) {
        self.provider = provider
        self.limits = limits
    }

    func scan(roots: [TokenHistoryRoot], now: Date, calendar: Calendar = .current) async throws
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
        roots: [TokenHistoryRoot], now: Date, calendar: Calendar, cancellation: Cancellation
    ) throws -> TokenUsageSnapshot {
        try cancellation.check()
        var accumulator = try TokenDayAccumulator(now: now, calendar: calendar)
        lastWork = Work()
        var visited = Set<String>()
        let rootIdentities = roots.compactMap { root -> RootIdentity? in
            let url = root.url.resolvingSymlinksInPath().standardizedFileURL
            return visited.insert(url.path).inserted
                ? RootIdentity(url, account: root.account) : nil
        }
        if rootIdentities != discoveryRoots || discoveryStart != accumulator.start {
            discoveryRoots = rootIdentities
            discoveryStart = accumulator.start
            discovery = nil
            inventory.removeAll()
            owners.removeAll()
            cache.removeAll()
        }
        let sweep = discovery ?? Discovery(roots: rootIdentities)
        discovery = sweep
        try discoverPage(sweep, since: accumulator.start, cancellation: cancellation)
        accumulator.isPartial = !sweep.isComplete || sweep.hadErrors || sweep.exceededFileLimit
        // An account's history is partial until discovery of its own folders succeeds.
        var partialAccounts = Set(
            rootIdentities.indices.filter {
                sweep.exceededFileLimit || !sweep.finished.contains($0)
                    || sweep.erroredRoots.contains($0)
            }.map { rootIdentities[$0].account })
        func owner(of path: String) -> String? { owners[path].map { rootIdentities[$0].account } }
        func markPartial(_ path: String) {
            accumulator.isPartial = true
            if let account = owner(of: path) { partialAccounts.insert(account) }
        }
        let urls = newestFiles(inventory).map { URL(fileURLWithPath: $0.key) }
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
                markPartial(url.path)
            } catch {
                markPartial(url.path)
                cache.removeValue(forKey: url.path)
            }
            if let state = cache[url.path] {
                records += state.parser.events.count + state.parser.codex.events.count
                if records > limits.records {
                    cache.removeValue(forKey: url.path)
                    markPartial(url.path)
                }
            }
        }
        lastWork.cachedFiles = cache.count
        lastWork.cachedRecords = cache.values.reduce(0) {
            $0 + $1.parser.events.count + $1.parser.codex.events.count
        }
        let paths = cache.keys.sorted()
        let owned = Dictionary(grouping: paths, by: owner(of:))
        var accounts: [String: TokenUsageSnapshot] = [:]
        for account in Set(rootIdentities.map(\.account)) {
            var scoped = accumulator
            scoped.isPartial = partialAccounts.contains(account)
            accounts[account] = try history(
                owned[account, default: []], into: scoped, cancellation: cancellation)
        }
        let total = try history(
            paths, into: accumulator, accounts: accounts, cancellation: cancellation)
        try cancellation.check()
        return total
    }

    /// Counts the cached records of `paths`. Copies of one response or session count once.
    private func history(
        _ paths: [String], into base: TokenDayAccumulator,
        accounts: [String: TokenUsageSnapshot] = [:], cancellation: Cancellation
    ) throws -> TokenUsageSnapshot {
        var accumulator = base
        var hasRecords = false
        var events: [String: TokenEvent] = [:]
        var sessions: [String: CodexTokenLog] = [:]
        for path in paths {
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
        return accumulator.snapshot(provider: provider, hasRecords: hasRecords, accounts: accounts)
    }

    private func newestFiles(_ files: [String: Date]) -> [(key: String, value: Date)] {
        Array(
            files.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.prefix(max(0, limits.files)))
    }

    private func discoverPage(_ sweep: Discovery, since start: Date, cancellation: Cancellation)
        throws
    {
        var page: [String: Date] = [:]
        defer {
            // Save consumed entries even if cancellation interrupts this page. A
            // resumed cursor must never skip metadata collected before cancellation.
            let discovered = sweep.files.merging(page, uniquingKeysWith: { _, new in new })
            sweep.exceededFileLimit = sweep.exceededFileLimit || discovered.count > limits.files
            sweep.files = Dictionary(uniqueKeysWithValues: newestFiles(discovered))
            if sweep.isComplete && !sweep.hadErrors {
                inventory = sweep.files
            } else {
                // An incomplete page is not evidence that an earlier file was deleted.
                inventory = Dictionary(
                    uniqueKeysWithValues: newestFiles(
                        inventory.merging(page, uniquingKeysWith: { _, new in new })))
            }
            cache = cache.filter { inventory[$0.key] != nil }
            owners = owners.filter { inventory[$0.key] != nil || sweep.files[$0.key] != nil }
            if sweep.isComplete { discovery = nil }
        }
        while lastWork.directoryEntries < limits.directoryEntries,
            lastWork.discoveredFiles < limits.files
        {
            guard let (url, root) = try sweep.next(cancellation: cancellation) else { break }
            lastWork.directoryEntries += 1
            let matches =
                provider == .grok
                ? url.lastPathComponent == "updates.jsonl" : url.pathExtension == "jsonl"
            guard matches else { continue }
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
            ])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                sweep.erroredRoots.insert(root)
                continue
            }
            let modified = values?.contentModificationDate ?? .distantFuture
            guard modified >= start else { continue }
            page[url.path] = modified
            // Nested roots find one file twice. The earlier configured root keeps it.
            owners[url.path] = min(owners[url.path] ?? root, root)
            lastWork.discoveredFiles += 1
        }
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
