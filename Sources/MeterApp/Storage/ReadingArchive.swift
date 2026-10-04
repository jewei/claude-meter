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
        /// Providers recorded or forgotten this launch. A later load never brings back their
        /// saved values.
        var recorded: Set<ProviderID> = []
        var isWriteScheduled = false
    }

    public init(file: URL) {
        self.file = file
    }

    /// `~/Library/Application Support/ClaudeMeter/readings.json` (`ClaudeMeter Debug` for a
    /// development build).
    public static var standardFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(AppIdentity.folderName)/readings.json")
    }

    /// Reads the saved readings. A missing or unreadable file reads as empty. Each provider
    /// loads on its own: an entry that does not decode (an unknown provider or window kind,
    /// for example from another version) is skipped, and the others still load. A provider
    /// that was recorded or forgotten before the load keeps that newer value: it is neither
    /// merged nor returned.
    public func load() async -> [ProviderID: ProviderUsage] {
        let file = file
        let loaded: [ProviderID: ProviderUsage]
        do {
            let data = try await BlockingIO.run(timeout: .seconds(5)) { _ in
                try LocalFile.read(file, maxBytes: Self.maxFileBytes)
            }
            let entries = try JSONDecoder.meter.decode([String: Entry].self, from: data)
            var readings: [ProviderID: ProviderUsage] = [:]
            var skipped = 0
            for (key, entry) in entries {
                guard let id = ProviderID(rawValue: key), let usage = entry.usage,
                    usage.provider == id
                else {
                    skipped += 1
                    continue
                }
                if let usage = usage.persistable { readings[id] = usage }
            }
            if skipped > 0 {
                log.warning("Skipped \(skipped) saved readings that did not load.")
            }
            loaded = readings
        } catch LocalFile.ReadError.notFound {
            loaded = [:]
        } catch {
            log.warning("Ignored the saved readings: \(error.localizedDescription)")
            loaded = [:]
        }
        return state.withLock { state in
            let older = loaded.filter { !state.recorded.contains($0.key) }
            state.readings.merge(older) { current, _ in current }
            return older
        }
    }

    /// One saved provider value, or nil when it does not decode.
    private struct Entry: Decodable {
        let usage: ProviderUsage?

        init(from decoder: any Decoder) throws {
            usage = try? ProviderUsage(from: decoder)
        }
    }

    /// Records the newest value for a provider, or nil to forget it, and schedules a write.
    public func record(_ usage: ProviderUsage?, for provider: ProviderID) {
        let needsWrite = state.withLock { state -> Bool in
            state.readings[provider] = usage?.persistable
            state.recorded.insert(provider)
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
            // An existing folder keeps its mode, so set it on every write. The atomic write
            // creates the file with the default mode before it becomes 0600; a private folder
            // keeps other users out for that moment.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
