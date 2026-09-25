import ClaudeMeterCore
import Foundation

public struct CodexAccount: Identifiable, Sendable, Equatable {
    public let home: URL
    public let isImplicit: Bool
    public let customName: String?
    public var id: String { home.path }
    public var defaultName: String { isImplicit ? "Codex" : home.lastPathComponent }
    public var displayName: String {
        let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? defaultName : name
    }
    public init(home: URL, isImplicit: Bool, customName: String?) {
        self.home = home
        self.isImplicit = isImplicit
        self.customName = customName
    }
}

public struct CodexConfiguration: Sendable {
    public let accounts: [CodexAccount]
    public init(accounts: [CodexAccount]) {
        self.accounts = accounts
    }
}

typealias CodexIdentityLoadOperation = @Sendable (CodexAccount) -> CodexCredentialIdentity

/// At most one blocked read per home, with an independent worker limit.
final class CodexIdentityReadGate: @unchecked Sendable {
    let budget = Timeout.TaskBudget(limit: 64)
    private let lock = NSLock()
    private var active: Set<String> = []

    func read(_ account: CodexAccount, loader: CodexIdentityLoadOperation) throws
        -> CodexCredentialIdentity
    {
        let inserted = lock.withLock { active.insert(account.id).inserted }
        guard inserted else { throw TimeoutCapacityError() }
        defer { _ = lock.withLock { active.remove(account.id) } }
        return loader(account)
    }
}

/// One provider, with an ordered list of homes. Previous quota state comes from
/// UsageStore. Only ownership metadata and the existing disk archive live here.
public final class CodexProviderAdapter: UsageProvider, Sendable {
    public let id: ProviderID = .codex
    public let ownsDeadline = true
    private let configuration: @MainActor @Sendable () async -> CodexConfiguration
    private let persistence: CodexReadingStore
    private let identityLoader: CodexIdentityLoadOperation
    private let identityGate = CodexIdentityReadGate()
    private let budget = Timeout.TaskBudget(limit: 6)
    private let timeoutSeconds: TimeInterval
    private let perAccountTimeoutSeconds: TimeInterval
    private let fetchAccount: @Sendable (CodexAccount, Date) async throws -> CodexUsage

    // Only the newest in-progress refresh has staged metadata. These values are
    // consumed by fetch/commit, never used as a second last-good usage cache.
    private struct Preflight: Sendable {
        let config: CodexConfiguration
        let deadline: TimeInterval
        let allowance: TimeInterval
        let archive: [String: CodexReadingStore.Entry]
        let identities: [String: CodexCredentialIdentity]
    }
    private struct PendingSave: Sendable {
        let entries: [String: CodexReadingStore.Entry]
        let owners: [String: CodexReadingStore.OwnerStamp]
        let diagnostics: [String: CodexSourceDiagnostic]
    }
    @MainActor private var activeRefreshID: UUID?
    @MainActor private var preflight: Preflight?
    @MainActor private var pendingSave: PendingSave?

    @MainActor
    public init(
        configuration: @escaping @MainActor @Sendable () async -> CodexConfiguration,
        defaults: UserDefaults = .standard,
        timeoutSeconds: TimeInterval = 60,
        perAccountTimeoutSeconds: TimeInterval = 60,
        identityLoader: @escaping @Sendable (CodexAccount) -> CodexCredentialIdentity = {
            CodexOAuthCredentialsStore.identity(codexHome: $0.home)
        },
        fetchAccount:
            @escaping @Sendable (CodexAccount, Date) async throws -> CodexUsage = {
                try await CodexUsageProvider(codexHome: $0.home).fetchUsage(now: $1)
            }
    ) {
        self.configuration = configuration
        self.persistence = CodexReadingStore(defaults: defaults)
        self.timeoutSeconds = timeoutSeconds
        self.perAccountTimeoutSeconds = perAccountTimeoutSeconds
        self.identityLoader = identityLoader
        self.fetchAccount = fetchAccount
    }

    @MainActor
    public func validatePrevious(
        _ previous: ProviderSnapshot?, now: Date, refreshID: UUID
    ) async throws -> ProviderSnapshot? {
        try Task.checkCancellation()
        activeRefreshID = refreshID
        preflight = nil
        pendingSave = nil
        let config = await configuration()
        try Task.checkCancellation()
        guard activeRefreshID == refreshID else { throw CancellationError() }
        let timeout = timeoutSeconds.isFinite ? max(0, timeoutSeconds) : 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let allowance = min(2, timeout / 4)
        let archive = await persistence.entries()
        try Task.checkCancellation()
        guard activeRefreshID == refreshID else { throw CancellationError() }
        let owners = persistence.owners
        let before = await identities(config.accounts, timeout: allowance)
        try Task.checkCancellation()
        guard activeRefreshID == refreshID else { throw CancellationError() }
        let previousByID = Dictionary(
            (previous?.accounts ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var valid: [String: ProviderAccountSnapshot] = [:]
        for account in config.accounts {
            guard let owner = before[account.id]?.ownerID else { continue }
            if let prior = previousByID[account.id], let observedAt = prior.observedAt {
                let stamp = owners[account.id]
                let entry = archive[account.id]
                let owned =
                    stamp?.ownerID == owner && stamp?.observedAt == observedAt
                    || entry?.ownerID == owner && entry?.lastSuccessfulAt == observedAt
                if owned {
                    var renamed = prior
                    renamed.label = account.displayName
                    valid[account.id] = renamed
                }
            } else if previousByID[account.id] == nil, let entry = archive[account.id],
                entry.ownerID == owner
            {
                valid[account.id] = entry.usage.providerAccountSnapshot(
                    id: account.id, label: account.displayName, observedAt: entry.lastSuccessfulAt)
            }
        }
        preflight = Preflight(
            config: config, deadline: deadline, allowance: allowance,
            archive: archive, identities: before)
        return snapshot(config.accounts.compactMap { valid[$0.id] }, now: now)
    }

    public func fetch(
        now: Date, previous: ProviderSnapshot?, refreshID: UUID
    ) async throws -> ProviderSnapshot {
        let prepared = try await takePreflight(refreshID)
        let config = prepared.config
        let deadline = prepared.deadline
        let allowance = prepared.allowance
        let archive = prepared.archive
        let before = prepared.identities
        let valid = Dictionary(
            (previous?.accounts ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let fetched = await fetchAccounts(
            config, now: now,
            deadline: deadline - allowance)
        let after = await identities(
            config.accounts,
            timeout: min(allowance, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        try Task.checkCancellation()
        var accounts: [ProviderAccountSnapshot] = []
        var saved: [String: CodexReadingStore.Entry] = [:]
        var acceptedOwners: [String: CodexReadingStore.OwnerStamp] = [:]
        var diagnostics: [String: CodexSourceDiagnostic] = [:]
        for account in config.accounts {
            let attempt = fetched[account.id]
            let attemptedAt = attempt?.attemptedAt ?? Date()
            guard let original = before[account.id], let current = after[account.id],
                original.acceptsResult(after: current)
            else {
                accounts.append(
                    unavailable(
                        account,
                        error:
                            "Codex sign-in changed or could not be verified. Refresh again.",
                        at: attemptedAt))
                continue
            }
            var normalized: ProviderAccountSnapshot
            switch attempt?.result {
            case .success(let usage):
                normalized = usage.providerAccountSnapshot(
                    id: account.id, label: account.displayName, observedAt: attemptedAt)
                if let owner = current.ownerID {
                    saved[account.id] = .init(
                        usage: usage, lastSuccessfulAt: attemptedAt, ownerID: owner)
                }
                diagnostics[account.id] = CodexSourceDiagnostic(usage: usage)
            case .failure(let error):
                let message = UsageProviderFailure(error).message
                if (error as? CodexOAuthCredentialsError) != .apiKeyOnly,
                    var prior = valid[account.id]
                {
                    prior.isStale = true
                    prior.lastError = message
                    normalized = prior
                    if let entry = archive[account.id], entry.ownerID == current.ownerID,
                        entry.lastSuccessfulAt == prior.observedAt
                    {
                        saved[account.id] = entry
                        diagnostics[account.id] = CodexSourceDiagnostic(usage: entry.usage)
                    }
                } else {
                    normalized = unavailable(account, error: message, at: attemptedAt)
                }
            case nil:
                normalized = unavailable(
                    account, error: "Codex refresh did not complete.", at: attemptedAt)
            }
            normalized.lastAttemptAt = attemptedAt
            if let owner = current.ownerID, let observedAt = normalized.observedAt {
                acceptedOwners[account.id] = .init(ownerID: owner, observedAt: observedAt)
            }
            accounts.append(normalized)
        }
        try await stageSave(
            PendingSave(entries: saved, owners: acceptedOwners, diagnostics: diagnostics),
            refreshID: refreshID)
        return snapshot(accounts, now: now)
    }

    @MainActor private func takePreflight(_ refreshID: UUID) throws -> Preflight {
        try Task.checkCancellation()
        guard activeRefreshID == refreshID, let prepared = preflight else {
            throw CancellationError()
        }
        preflight = nil
        return prepared
    }

    @MainActor private func stageSave(_ save: PendingSave, refreshID: UUID) throws {
        try Task.checkCancellation()
        guard activeRefreshID == refreshID else { throw CancellationError() }
        pendingSave = save
    }

    @MainActor public func didAccept(_ snapshot: ProviderSnapshot, refreshID: UUID) {
        guard activeRefreshID == refreshID, let save = pendingSave else {
            return
        }
        pendingSave = nil
        activeRefreshID = nil
        persistence.accept(save.entries, owners: save.owners, diagnostics: save.diagnostics)
    }

    public func waitForPersistence() async {
        await persistence.waitForWrites()
    }

    /// Diagnostic metadata is separate from normalized quota state and contains no credentials.
    @MainActor public var sourceDiagnostics: [String: CodexSourceDiagnostic] {
        persistence.diagnostics
    }

    private func snapshot(_ accounts: [ProviderAccountSnapshot], now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .codex, accounts: accounts,
            fetchedAt: accounts.compactMap(\.observedAt).max() ?? now)
    }

    private func unavailable(_ account: CodexAccount, error: String, at date: Date)
        -> ProviderAccountSnapshot
    {
        ProviderAccountSnapshot(
            id: account.id, label: account.displayName, windows: [],
            observedAt: nil, lastError: error, lastAttemptAt: date)
    }

    private func identities(_ accounts: [CodexAccount], timeout: TimeInterval) async
        -> [String: CodexCredentialIdentity]
    {
        guard timeout > 0, !Task.isCancelled else { return [:] }
        return await withTaskGroup(of: (String, CodexCredentialIdentity?).self) { group in
            for account in accounts {
                group.addTask { [identityGate, identityLoader] in
                    let identity = try? await Timeout.run(
                        seconds: timeout, budget: identityGate.budget
                    ) {
                        try identityGate.read(account, loader: identityLoader)
                    }
                    return (account.id, identity)
                }
            }
            var result: [String: CodexCredentialIdentity] = [:]
            for await (id, identity) in group { result[id] = identity }
            return result
        }
    }

    private struct Attempt: Sendable {
        let result: Result<CodexUsage, Error>
        let attemptedAt: Date
    }

    private func fetchAccounts(_ config: CodexConfiguration, now: Date, deadline: TimeInterval)
        async -> [String: Attempt]
    {
        var result: [String: Attempt] = [:]
        var pending = config.accounts[...]
        // At most three requests run at once. A free slot starts the next account at
        // once, so one stalled account does not hold back the others.
        await withTaskGroup(of: (String, Attempt).self) { group in
            var running = 0
            while true {
                while running < 3, let account = pending.first, !Task.isCancelled {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { break }
                    pending.removeFirst()
                    let accountTimeout = min(perAccountTimeoutSeconds, remaining)
                    group.addTask { [budget, fetchAccount] in
                        let value: Result<CodexUsage, Error>
                        do {
                            let usage = try await Timeout.run(
                                seconds: accountTimeout, budget: budget
                            ) {
                                try await fetchAccount(account, now)
                            }
                            value = .success(usage)
                        } catch { value = .failure(error) }
                        return (account.id, Attempt(result: value, attemptedAt: Date()))
                    }
                    running += 1
                }
                guard let (id, attempt) = await group.next() else { break }
                running -= 1
                result[id] = attempt
            }
        }
        // Accounts left without a slot ran out of provider deadline.
        if !Task.isCancelled {
            for account in pending {
                result[account.id] = Attempt(
                    result: .failure(TimeoutError(seconds: timeoutSeconds)), attemptedAt: Date())
            }
        }
        return result
    }
}
