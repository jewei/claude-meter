import ClaudeMeterCore
import Foundation

public struct CodexSourceDiagnostic: Sendable {
    public let source: String
    public let authentication: String?
    init(usage: CodexUsage) {
        source = usage.source.rawValue
        authentication = usage.authMode?.rawValue
    }
}

/// The existing archive format remains provider-local. No source fingerprints or
/// emails are saved. Ownership stamps are metadata, not a second usage cache.
@MainActor
final class CodexReadingStore {
    struct Entry: Codable, Sendable {
        var usage: CodexUsage
        let lastSuccessfulAt: Date
        let ownerID: String?
    }
    struct OwnerStamp: Sendable {
        let ownerID: String
        let observedAt: Date
    }
    private let archive: CodexArchiveIO
    // Keep only the newest queued archive until its write completes. A new refresh
    // can validate it without waiting for disk or restoring an older durable value.
    private var pendingArchive: (id: UUID, entries: [String: Entry])?
    private(set) var owners: [String: OwnerStamp] = [:]
    private(set) var diagnostics: [String: CodexSourceDiagnostic] = [:]

    init(defaults: UserDefaults) { archive = CodexArchiveIO(defaults: defaults) }

    func entries() async -> [String: Entry] {
        if let pendingArchive { return pendingArchive.entries }
        return await archive.read()
    }

    func accept(
        _ entries: [String: Entry], owners: [String: OwnerStamp],
        diagnostics: [String: CodexSourceDiagnostic]
    ) {
        self.owners = owners
        self.diagnostics = diagnostics
        pendingArchive = (UUID(), entries)
        archive.enqueue(entries)
    }

    func waitForWrites() async {
        let id = pendingArchive?.id
        await archive.waitForWrites()
        if pendingArchive?.id == id { pendingArchive = nil }
    }
}

/// All archive access runs on one dedicated serial queue. Submission is synchronous
/// with acceptance, so write order cannot change when async callers resume out of order.
private final class CodexArchiveIO: @unchecked Sendable {
    private static let storageKey = "codexLastGoodReadings.v1"
    private struct Archive: Codable {
        var schemaVersion = 2
        let entries: [String: CodexReadingStore.Entry]
    }
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.jewei.claudemeter.codex-archive", qos: .utility)

    init(defaults: UserDefaults) { self.defaults = defaults }

    func read() async -> [String: CodexReadingStore.Entry] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readOnQueue()) }
        }
    }

    func enqueue(_ entries: [String: CodexReadingStore.Entry]) {
        queue.async { self.writeOnQueue(entries) }
    }

    func waitForWrites() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func readOnQueue() -> [String: CodexReadingStore.Entry] {
        guard let data = defaults.data(forKey: Self.storageKey),
            let archive = try? JSONDecoder().decode(Archive.self, from: data),
            archive.schemaVersion == 2,
            archive.entries.values.allSatisfy({
                PersistedDateBounds.contains($0.lastSuccessfulAt)
                    && PersistedDateBounds.contains($0.usage.updatedAt)
            })
        else { return [:] }
        return archive.entries.filter { $0.value.ownerID != nil }
    }

    private func writeOnQueue(_ entries: [String: CodexReadingStore.Entry]) {
        let safe = entries.mapValues { entry in
            var entry = entry
            entry.usage.accountEmail = nil
            entry.usage.maskedAccountEmail = nil
            return entry
        }
        guard let data = try? JSONEncoder().encode(Archive(entries: safe)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
