import Foundation
import MeterDomain
import MeterPlatform

/// Saves the latest readings so the next launch can show them before its first refresh.
///
/// Only observations with an identity owner are saved; credential-derived owners never reach
/// the disk. Writes are coalesced and run on a private serial queue, so the newest recorded
/// value always wins and the main thread never waits for the disk.
public final class ReadingArchive: Sendable {
    public static let maxFileBytes = 4 * 1024 * 1024

    public let file: URL
    private let state = Locked(State())
    private let queue = DispatchQueue(label: "com.jewei.claudemeter.reading-archive", qos: .utility)
    private let log = Log(.app)

    private struct State: Sendable {
        var readings: [ProviderID: ProviderUsage] = [:]
        var isWriteScheduled = false
    }

    public init(file: URL) {
        self.file = file
    }

    /// `~/Library/Application Support/ClaudeMeter/readings.json`.
    public static var standardFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ClaudeMeter/readings.json")
    }

    /// Reads the saved readings. A missing or unreadable file reads as empty.
    public func load() async -> [ProviderID: ProviderUsage] {
        let file = file
        let loaded: [ProviderID: ProviderUsage]
        do {
            let data = try await BlockingIO.run(timeout: .seconds(2)) { _ in
                try LocalFile.read(file, maxBytes: Self.maxFileBytes)
            }
            let decoded = try JSONDecoder.meter.decode([ProviderID: ProviderUsage].self, from: data)
            loaded = decoded.compactMapValues(\.persistable)
        } catch LocalFile.ReadError.notFound {
            loaded = [:]
        } catch {
            log.warning("Ignored the saved readings: \(error.localizedDescription)")
            loaded = [:]
        }
        state.withLock { state in
            state.readings.merge(loaded) { current, _ in current }
        }
        return loaded
    }

    /// Records the newest value for a provider, or nil to forget it, and schedules a write.
    public func record(_ usage: ProviderUsage?, for provider: ProviderID) {
        let needsWrite = state.withLock { state -> Bool in
            state.readings[provider] = usage?.persistable
            defer { state.isWriteScheduled = true }
            return !state.isWriteScheduled
        }
        guard needsWrite else { return }
        queue.async { [self] in write() }
    }

    /// Waits for scheduled writes. For tests.
    func flush() {
        queue.sync {}
    }

    private func write() {
        let readings = state.withLock { state in
            state.isWriteScheduled = false
            return state.readings
        }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder.meter.encode(readings)
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            log.error("Could not save readings", error)
        }
    }
}

extension ProviderUsage {
    /// The part that may be stored: observed accounts with an identity owner.
    var persistable: ProviderUsage? {
        let accounts = accounts.filter { $0.hasObservation && $0.owner?.isPersistable == true }
        return accounts.isEmpty ? nil : ProviderUsage(provider: provider, accounts: accounts)
    }
}
