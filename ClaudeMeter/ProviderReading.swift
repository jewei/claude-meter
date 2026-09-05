import ClaudeMeterCore
import ClaudeMeterProviders
import Foundation

/// One coherent fetch lifecycle for every optional provider. Failed refreshes
/// retain the last successful value as stale data whenever one exists.
enum ReadingState<Value: Sendable>: Sendable {
    case current(value: Value, polledAt: Date)
    case stale(value: Value, polledAt: Date, error: String)
    case failed(error: String, lastPolledAt: Date?)

    var value: Value? {
        switch self {
        case .current(let value, _), .stale(let value, _, _): value
        case .failed: nil
        }
    }

    var error: String? {
        switch self {
        case .current: nil
        case .stale(_, _, let error), .failed(let error, _): error
        }
    }

    var lastPolledAt: Date? {
        switch self {
        case .current(_, let date), .stale(_, let date, _): date
        case .failed(_, let date): date
        }
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

struct CodexAccountReading: Identifiable, Sendable {
    let account: CodexAccount
    let state: ReadingState<CodexUsage>
    /// Time of the latest fetch attempt. This differs from `lastSuccessfulAt`
    /// when a refresh fails after a usable observation.
    let lastAttemptAt: Date?

    init(
        account: CodexAccount,
        state: ReadingState<CodexUsage>,
        lastAttemptAt: Date? = nil
    ) {
        self.account = account
        self.state = state
        self.lastAttemptAt = lastAttemptAt
    }

    var id: String { account.id }
    var usage: CodexUsage? { state.value }
    var error: String? { state.error }
    var lastSuccessfulAt: Date? { state.lastPolledAt }
    var latestAttemptFailed: Bool { error != nil }

    func observationIsStale(
        asOf now: Date = Date(),
        shared: UserDefaults? = AppGroupConfig.sharedDefaults,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard usage != nil else { return false }
        return AppGroupConfig.isSnapshotStale(
            lastPollAt: lastSuccessfulAt,
            shared: shared,
            defaults: defaults,
            now: now)
    }
}

/// Durable last-good Codex observations. Refresh errors are deliberately not
/// persisted: they describe one process's latest attempt, while the cache exists
/// to make a cold/offline launch honest. Account email is stripped at this
/// persistence boundary because Codex cards identify homes by user-chosen name.
@MainActor
struct CodexReadingStore {
    private static let storageKey = "codexLastGoodReadings.v1"

    private struct Archive: Codable {
        var schemaVersion = 1
        var entries: [String: Entry]
    }

    private struct Entry: Codable {
        var usage: CodexUsage
        var lastSuccessfulAt: Date
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restore(accounts: [CodexAccount]) -> [CodexAccountReading] {
        guard let archive = readArchive(), archive.schemaVersion == 1 else { return [] }
        return accounts.compactMap { account in
            guard let entry = archive.entries[account.id] else { return nil }
            return CodexAccountReading(
                account: account,
                state: .current(value: entry.usage, polledAt: entry.lastSuccessfulAt))
        }
    }

    func save(_ readings: [CodexAccountReading]) {
        let entries: [String: Entry] = Dictionary(
            uniqueKeysWithValues: readings.compactMap { reading in
                guard
                    var usage = reading.usage,
                    let lastSuccessfulAt = reading.lastSuccessfulAt
                else { return nil }
                usage.accountEmail = nil
                usage.maskedAccountEmail = nil
                return (reading.id, Entry(usage: usage, lastSuccessfulAt: lastSuccessfulAt))
            })
        guard
            let data = try? JSONEncoder().encode(Archive(entries: entries))
        else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func readArchive() -> Archive? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        guard let archive = try? JSONDecoder().decode(Archive.self, from: data),
            archive.entries.values.allSatisfy({ entry in
                PersistedDateBounds.contains(entry.lastSuccessfulAt)
                    && PersistedDateBounds.contains(entry.usage.updatedAt)
            })
        else { return nil }
        return archive
    }
}
