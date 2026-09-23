import ClaudeMeterCore
import Foundation

/// The legacy file format stays at this boundary. Every blocking SnapshotStore
/// operation runs on this queue, including store creation and upgrade import.
final class ClaudeReadingStore: @unchecked Sendable {
    private let directory: URL?
    private let queue: DispatchQueue
    private var store: SnapshotStore?

    init(
        directory: URL?,
        queue: DispatchQueue = DispatchQueue(
            label: "com.jewei.claudemeter.claude-archive", qos: .utility)
    ) {
        self.directory = directory
        self.queue = queue
    }

    private func storage() throws -> SnapshotStore {
        if let store { return store }
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        let created =
            try directory.map { SnapshotStore(directory: $0) } ?? SnapshotStore.applicationSupport()
        if directory == nil { try created.importLegacyAppGroupSnapshotIfNeeded() }
        store = created
        return created
    }

    func read() async -> ClaudeUsageSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: try? self.storage().readLatest())
            }
        }
    }

    /// Share the same queue as restoration/writes; a separate startup importer
    /// could otherwise overwrite an accepted observation with an older snapshot.
    func importLegacySnapshotIfNeeded() async throws {
        if directory == nil {
            guard !UserDefaults.standard.bool(forKey: "didImportLegacyAppGroupSnapshot.v1"),
                !KeychainGateway.testFrameworkIsLoaded()
            else { return }
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    _ = try self.storage()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func enqueue(_ snapshot: ClaudeUsageSnapshot?, error: String?) {
        queue.async {
            do {
                let store = try self.storage()
                if let snapshot { try store.writeLatest(snapshot) }
                if let error {
                    try store.writeLastError(LastErrorRecord(message: error))
                } else {
                    try store.clearLastError()
                }
            } catch {
                MeterLog.logger(.poll).error("Claude persistence failed", error: error)
            }
        }
    }

    func waitForWrites() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
