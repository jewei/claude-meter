import Foundation

/// Which rolling window a history sample belongs to. Weekly-all and weekly-Opus
/// share a 7-day span but are tracked separately (different limits).
public enum UsageHistoryWindow: String, Codable, Sendable, CaseIterable {
    case session
    case weekly
    case weeklyOpus

    /// Nominal span in minutes — used to place a sample within its cycle.
    public var spanMinutes: Int {
        switch self {
        case .session: return 5 * 60
        case .weekly, .weeklyOpus: return 7 * 24 * 60
        }
    }
}

/// One observation of a window's used-% at a point in time, scoped to an account.
public struct UsageHistorySample: Codable, Sendable, Equatable {
    public let accountKey: String
    public let window: UsageHistoryWindow
    public let sampledAt: Date
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowMinutes: Int

    public init(
        accountKey: String,
        window: UsageHistoryWindow,
        sampledAt: Date,
        usedPercent: Double,
        resetsAt: Date?,
        windowMinutes: Int? = nil
    ) {
        self.accountKey = accountKey
        self.window = window
        self.sampledAt = sampledAt
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes ?? window.spanMinutes
    }

    /// Fraction of the window elapsed at `sampledAt` (0…1), or nil when `resetsAt`
    /// is absent or implausible (already past, or more than a span away).
    public var elapsedFraction: Double? {
        guard let resetsAt else { return nil }
        let span = Double(windowMinutes) * 60
        guard span > 0 else { return nil }
        let untilReset = resetsAt.timeIntervalSince(sampledAt)
        guard untilReset > 0, untilReset <= span else { return nil }
        return (span - untilReset) / span
    }
}

/// Persisted, per-account, per-window time series of usage observations.
///
/// Append-only JSONL under Application Support (not the App Group — the widget
/// doesn't need raw history, and this keeps the shared container small). Sampling is
/// throttled (a new point only on a reset change, a ≥1-pt move, or every 30 min) and
/// pruned to 56 days, so the file stays small despite a 60 s poll. The file is
/// compacted on load and whenever a prune trims it; otherwise each accepted sample is
/// a single appended line.
public actor UsageHistoryStore {

    private struct Key: Hashable {
        let account: String
        let window: UsageHistoryWindow
    }

    public static let retentionDays = 56
    /// Hard cap on retained samples, a backstop against unbounded in-session growth.
    public static let maxSamples = 20_000
    static let minInterval: TimeInterval = 30 * 60
    static let minDeltaPercent: Double = 1.0
    static let resetBucket: TimeInterval = 5 * 60

    private let fileURL: URL?
    private var samples: [UsageHistorySample] = []
    private var lastAcceptedByKey: [Key: UsageHistorySample] = [:]
    private var didLoad = false

    public init(fileURL: URL? = UsageHistoryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: false)
        else { return nil }
        return
            base
            .appendingPathComponent("ClaudeMeter", isDirectory: true)
            .appendingPathComponent("usage-history.jsonl")
    }

    // MARK: - Recording

    /// Records `sample` if it clears the throttle (otherwise a no-op). Throttle keys on
    /// the (account, window) pair so each window keeps its own cadence.
    public func record(_ sample: UsageHistorySample) {
        loadIfNeeded()
        let key = Key(account: sample.accountKey, window: sample.window)
        if let last = lastAcceptedByKey[key], !Self.shouldAccept(candidate: sample, last: last) {
            return
        }
        samples.append(sample)
        lastAcceptedByKey[key] = sample
        if pruneAndCap(reference: sample.sampledAt) {
            rewriteFile()
        } else {
            appendLine(sample)
        }
    }

    /// Pure throttle decision (exposed for tests): accept when there's a reset change,
    /// a ≥1-pt move, or ≥30 min since the last accepted sample for this window.
    static func shouldAccept(candidate: UsageHistorySample, last: UsageHistorySample) -> Bool {
        if bucketedReset(candidate.resetsAt) != bucketedReset(last.resetsAt) { return true }
        if abs(candidate.usedPercent - last.usedPercent) >= minDeltaPercent { return true }
        if candidate.sampledAt.timeIntervalSince(last.sampledAt) >= minInterval { return true }
        return false
    }

    /// Rounds a reset timestamp to the nearest 5 min so jittery `resets_at` values from
    /// the same cycle compare equal.
    static func bucketedReset(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let secs = (date.timeIntervalSinceReferenceDate / resetBucket).rounded() * resetBucket
        return Date(timeIntervalSinceReferenceDate: secs)
    }

    // MARK: - Reading

    /// Samples for a window (optionally since a date), oldest first.
    public func samples(
        accountKey: String, window: UsageHistoryWindow, since: Date? = nil
    ) -> [UsageHistorySample] {
        loadIfNeeded()
        return samples
            .filter {
                $0.accountKey == accountKey && $0.window == window
                    && (since == nil || $0.sampledAt >= since!)
            }
            .sorted { $0.sampledAt < $1.sampledAt }
    }

    /// The user's *typical* used-% at the same point in past cycles of this window —
    /// "you're usually at X% by now". Groups samples by cycle (bucketed reset), takes
    /// each cycle's observation closest to `elapsedFraction` (within `tolerance`), and
    /// returns the median across cycles. Nil when no cycle has a nearby observation.
    public func typicalUsedPercent(
        accountKey: String, window: UsageHistoryWindow, atElapsedFraction fraction: Double,
        tolerance: Double = 0.05
    ) -> Double? {
        loadIfNeeded()
        let relevant = samples.filter { $0.accountKey == accountKey && $0.window == window }
        var byCycle: [Date: (used: Double, distance: Double)] = [:]
        for sample in relevant {
            guard let cycle = Self.bucketedReset(sample.resetsAt),
                let f = sample.elapsedFraction
            else { continue }
            let distance = abs(f - fraction)
            guard distance <= tolerance else { continue }
            if let existing = byCycle[cycle], existing.distance <= distance { continue }
            byCycle[cycle] = (sample.usedPercent, distance)
        }
        let values = byCycle.values.map(\.used).sorted()
        return Self.median(values)
    }

    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // MARK: - Persistence

    @discardableResult
    private func pruneAndCap(reference: Date) -> Bool {
        let before = samples.count
        let cutoff = reference.addingTimeInterval(-Double(Self.retentionDays) * 24 * 3600)
        samples.removeAll { $0.sampledAt < cutoff }
        if samples.count > Self.maxSamples {
            samples.sort { $0.sampledAt < $1.sampledAt }
            samples.removeFirst(samples.count - Self.maxSamples)
        }
        return samples.count != before
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let text = String(data: data, encoding: .utf8)
        else { return }
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                let sample = try? decoder.decode(UsageHistorySample.self, from: lineData)
            else { continue }
            samples.append(sample)
        }
        let reference = samples.map(\.sampledAt).max() ?? Date()
        _ = pruneAndCap(reference: reference)
        rebuildLastAccepted()
        rewriteFile()  // compact on every launch
    }

    private func rebuildLastAccepted() {
        lastAcceptedByKey.removeAll()
        for sample in samples.sorted(by: { $0.sampledAt < $1.sampledAt }) {
            lastAcceptedByKey[Key(account: sample.accountKey, window: sample.window)] = sample
        }
    }

    private func appendLine(_ sample: UsageHistorySample) {
        guard let fileURL, let line = encodeLine(sample) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            // File doesn't exist yet — create it with this line.
            try? line.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private func rewriteFile() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        var blob = Data()
        for sample in samples {
            guard let data = try? encoder.encode(sample) else { continue }
            blob.append(data)
            blob.append(0x0A)  // newline
        }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? blob.write(to: fileURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func encodeLine(_ sample: UsageHistorySample) -> Data? {
        guard var data = try? JSONEncoder().encode(sample) else { return nil }
        data.append(0x0A)
        return data
    }

    // MARK: - Testing

    func allSamplesForTesting() -> [UsageHistorySample] {
        loadIfNeeded()
        return samples
    }
}
