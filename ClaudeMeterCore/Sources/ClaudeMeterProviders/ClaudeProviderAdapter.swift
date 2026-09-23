import ClaudeMeterCore
import Foundation

public struct ClaudeConfiguration: Sendable, Equatable {
    public let mode: String
    public let configuredDirs: [String]
    public let disabledKeys: Set<String>
    public let thresholds: UsageThresholds

    public init(
        mode: String, configuredDirs: [String] = [], disabledKeys: Set<String> = [],
        thresholds: UsageThresholds = .default
    ) {
        self.mode = mode
        self.configuredDirs = configuredDirs
        self.disabledKeys = disabledKeys.subtracting(["claude"])
        self.thresholds = thresholds
    }
}

public struct ClaudeDiagnostics: Sendable {
    public init() {}
    public var sourceAttempts: [SourceAttempt] = []
    public var warnings: [ParseWarning] = []
    public var accountFailures: [String: MultiAccountOAuth.AccountFetchFailure] = [:]
    public var duplicateAccountKeys: Set<String> = []
    public var credentialIssue: OAuthCredentialIssue? {
        OAuthCredentialIssue.from(sourceAttempts: sourceAttempts)
    }
}

/// One Claude provider. UsageStore owns all previous quota values; this type keeps
/// only account metadata, request timing, diagnostics and unaccepted request data.
public final class ClaudeProviderAdapter: UsageProvider, Sendable {
    public let id: ProviderID = .claude
    public let ownsDeadline = true
    private let configuration: @MainActor @Sendable () -> ClaudeConfiguration
    private let persistence: ClaudeReadingStore
    private let discover: @Sendable (ClaudeConfiguration) throws -> [AccountConfig]
    private let primary:
        @Sendable (ClaudeConfiguration, [AccountConfig], Date) async throws -> ParseResult
    private let secondary:
        @Sendable ([AccountConfig], UsageThresholds, Date) async -> [MultiAccountOAuth
            .AccountFetchResult]
    private let budget = Timeout.TaskBudget(limit: 4)
    private struct Prepared: Sendable {
        let config: ClaudeConfiguration
        let accounts: [AccountConfig]
    }
    private struct Accepted: Sendable {
        let snapshot: ClaudeUsageSnapshot?
        let error: String?
        let diagnostics: ClaudeDiagnostics
        let organizations: [String: String]
        let primaryKey: String
        let attempts: [String: Date]
        let configuration: ClaudeConfiguration
    }
    @MainActor private var refreshID: UUID?
    @MainActor private var prepared: Prepared?
    @MainActor private var pending: Accepted?
    @MainActor private var lastConfiguration: ClaudeConfiguration?
    @MainActor private var secondaryAttempts: [String: Date] = [:]
    @MainActor private var organizations: [String: String] = [:]
    @MainActor private var primaryKey = "claude"
    @MainActor public private(set) var diagnostics = ClaudeDiagnostics()
    public var retryAt: Date? { OAuthPipeline.rateLimitedUntil() }

    @MainActor public init(
        configuration: @escaping @MainActor @Sendable () -> ClaudeConfiguration,
        directory: URL? = nil,
        discover: @escaping @Sendable (ClaudeConfiguration) throws -> [AccountConfig] = {
            ConfigDirDiscovery.discover(configuredDirs: $0.configuredDirs)
        },
        primary: (
            @Sendable (ClaudeConfiguration, [AccountConfig], Date) async throws -> ParseResult
        )? = nil,
        secondary:
            @escaping @Sendable ([AccountConfig], UsageThresholds, Date) async -> [MultiAccountOAuth
            .AccountFetchResult] = { accounts, thresholds, now in
                await MultiAccountOAuth.fetchAllResults(
                    accounts: accounts, home: FileManager.default.homeDirectoryForCurrentUser,
                    thresholds: thresholds, transport: ProviderHTTPClient.shared,
                    credentialsLoader: {
                        OAuthKeychain.loadResult(configDirPath: $0, isDefault: $1)
                    }, now: now)
            }
    ) {
        self.configuration = configuration
        self.persistence = ClaudeReadingStore(directory: directory)
        self.discover = discover
        self.primary =
            primary ?? { config, accounts, now in
                try await OAuthPipeline(
                    fallback: UnavailableClaudePipeline(), thresholds: config.thresholds,
                    accountConfigs: { accounts }
                ).poll(now: now)
            }
        self.secondary = secondary
    }

    /// Onboarding evidence only. This does not publish or keep a second usage reading.
    public func hasPersistedObservation() async -> Bool { await persistence.read() != nil }

    /// Startup compatibility work, also required when Claude usage is disabled.
    public func importLegacySnapshotIfNeeded() async throws {
        try await persistence.importLegacySnapshotIfNeeded()
    }

    @MainActor public func validatePrevious(
        _ previous: ProviderSnapshot?, now: Date, refreshID: UUID
    ) async throws -> ProviderSnapshot? {
        try Task.checkCancellation()
        self.refreshID = refreshID
        pending = nil
        prepared = nil
        let config = configuration()
        let modeChanged = lastConfiguration.map { $0.mode != config.mode } ?? false
        var valid = modeChanged ? nil : previous
        if valid == nil && !modeChanged, let archived = await persistence.read() {
            try check(refreshID)
            valid = ClaudeSnapshotAdapter.snapshot(archived, isStale: true)
            organizations = Dictionary(
                (archived.accounts ?? []).compactMap {
                    guard let org = $0.account?.organization else { return nil }
                    return ($0.id, org)
                }, uniquingKeysWith: { _, latest in latest })
        }
        let accounts: [AccountConfig]
        if config.mode == "auto" {
            accounts =
                (try? await Timeout.run(seconds: 5, budget: budget) { [discover] in
                    try discover(config)
                }) ?? []
        } else {
            accounts = []
        }
        try check(refreshID)
        prepared = Prepared(config: config, accounts: accounts)
        guard let valid else { return nil }
        return ProviderSnapshot(
            provider: .claude,
            accounts: valid.accounts.filter { !config.disabledKeys.contains($0.id) }.map {
                guard $0.isStale else { return $0 }
                var stale = Self.retained($0, error: $0.lastError, now: now)
                stale.lastAttemptAt = $0.lastAttemptAt
                return stale
            }, fetchedAt: valid.fetchedAt)
    }

    public func fetch(now: Date, previous: ProviderSnapshot?, refreshID: UUID) async throws
        -> ProviderSnapshot
    {
        let (prepared, lastPrimary, attempts, oldOrganizations, failures) = try await takePrepared(
            refreshID)
        let config = prepared.config
        let result: ParseResult
        do {
            result = try await Timeout.run(seconds: 60, budget: budget) { [primary] in
                try await primary(config, prepared.accounts, now)
            }
        } catch {
            try Task.checkCancellation()
            result = ParseResult(
                snapshot: nil, warnings: [],
                errors: [ParseError(UsageProviderFailure(error).message)],
                oauthAccountKey: lastPrimary,
                sourceAttempts: [.init(source: .oauth, outcome: .failed, reason: .requestFailed)])
        }
        try Task.checkCancellation()
        let key = result.oauthAccountKey ?? lastPrimary
        var values = Dictionary(
            (previous?.accounts ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest })
        var orgs = oldOrganizations
        var report = ClaudeDiagnostics()
        report.accountFailures = failures
        report.accountFailures.removeValue(forKey: key)
        report.sourceAttempts = result.sourceAttempts
        report.warnings = result.warnings
        var nextAttempts = attempts
        if let raw = result.snapshot, !raw.state.isStale {
            for account in ClaudeSnapshotAdapter.snapshot(raw).accounts {
                values[account.id] = account
                orgs[account.id] =
                    raw.accounts?.first { $0.id == account.id }?.account?.organization
                    ?? raw.account?.organization
            }
        } else if !config.disabledKeys.contains(key) {
            let message =
                OAuthCredentialIssue.from(sourceAttempts: result.sourceAttempts)?.displayText(
                    retryAt: retryAt, now: now)
                ?? result.errors.map(\.message).joined(separator: "; ")
            values[key] = Self.failed(
                values[key], id: key, label: ConfigDirDiscovery.label(forKey: key),
                error: message.isEmpty ? "Claude usage is unavailable." : message, now: now)
        }
        let enabled = prepared.accounts.filter {
            !config.disabledKeys.contains($0.id) && $0.id != key
        }
        let due = enabled.filter {
            attempts[$0.id].map { now.timeIntervalSince($0) >= 300 } ?? true
        }
        if config.mode == "auto", !due.isEmpty {
            let results = await secondary(due, config.thresholds, now)
            try Task.checkCancellation()
            let byID = Dictionary(
                results.map { ($0.accountKey, $0) }, uniquingKeysWith: { _, latest in latest })
            for account in due {
                nextAttempts[account.id] = now
                if let reading = byID[account.id]?.reading {
                    report.accountFailures.removeValue(forKey: account.id)
                    values[account.id] = ClaudeSnapshotAdapter.account(
                        AccountUsage(
                            id: reading.accountKey, label: reading.label,
                            account: AccountInfo(
                                loginMethod: "OAuth", organization: reading.organizationId,
                                email: reading.email, plan: reading.plan),
                            limits: reading.limits, lastSuccessfulPollAt: reading.fetchedAt,
                            severity: reading.severity), fallbackObservedAt: reading.fetchedAt)
                    orgs[account.id] = reading.organizationId
                } else {
                    let failure =
                        byID[account.id]?.failure
                        ?? (retryAt == nil ? .requestFailed : .rateLimited)
                    report.accountFailures[account.id] = failure
                    values[account.id] = Self.failed(
                        values[account.id], id: account.id, label: account.label,
                        error: failure.displayText, now: now)
                }
            }
        }
        // Keep configured order deterministic. An unmapped primary remains its own account.
        var order = config.mode == "auto" ? prepared.accounts.map(\.id) : [key]
        if !order.contains(key) { order.insert(key, at: 0) }
        // Discovery failure must not silently discard usable enabled last-good accounts.
        if config.mode == "auto" && prepared.accounts.isEmpty {
            order += values.keys.filter { !order.contains($0) }.sorted()
        }
        let accounts = order.filter { !config.disabledKeys.contains($0) }.map { id in
            values[id]
                ?? Self.failed(
                    nil, id: id, label: ConfigDirDiscovery.label(forKey: id),
                    error: "Claude usage is unavailable.", now: now)
        }
        orgs = orgs.filter { order.contains($0.key) && !config.disabledKeys.contains($0.key) }
        report.accountFailures = report.accountFailures.filter {
            order.contains($0.key) && !config.disabledKeys.contains($0.key)
        }
        report.duplicateAccountKeys = Set(
            Dictionary(grouping: orgs.keys, by: { orgs[$0]! }).values.filter { $0.count > 1 }
                .flatMap { $0 })
        let snapshot = ProviderSnapshot(
            provider: .claude, accounts: accounts,
            fetchedAt: accounts.compactMap(\.observedAt).max() ?? now)
        let error = accounts.compactMap(\.lastError).first
        let accepted = Accepted(
            snapshot: ClaudeSnapshotAdapter.legacySnapshot(snapshot, organizations: orgs, now: now),
            error: error, diagnostics: report, organizations: orgs, primaryKey: key,
            attempts: nextAttempts, configuration: config)
        try await stage(accepted, refreshID: refreshID)
        return snapshot
    }

    @MainActor private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard refreshID == id else { throw CancellationError() }
    }
    @MainActor private func takePrepared(_ id: UUID) throws -> (
        Prepared, String, [String: Date], [String: String],
        [String: MultiAccountOAuth.AccountFetchFailure]
    ) {
        try check(id)
        guard let prepared else { throw CancellationError() }
        self.prepared = nil
        return (
            prepared, primaryKey, lastConfiguration == prepared.config ? secondaryAttempts : [:],
            organizations, diagnostics.accountFailures
        )
    }
    @MainActor private func stage(_ accepted: Accepted, refreshID: UUID) throws {
        try check(refreshID)
        pending = accepted
    }
    @MainActor public func didAccept(_ snapshot: ProviderSnapshot, refreshID: UUID) {
        guard self.refreshID == refreshID, let accepted = pending else { return }
        pending = nil
        self.refreshID = nil
        diagnostics = accepted.diagnostics
        organizations = accepted.organizations
        primaryKey = accepted.primaryKey
        secondaryAttempts = accepted.attempts
        lastConfiguration = accepted.configuration
        persistence.enqueue(accepted.snapshot, error: accepted.error)
    }
    public func waitForPersistence() async { await persistence.waitForWrites() }

    private static func failed(
        _ previous: ProviderAccountSnapshot?, id: String, label: String, error: String, now: Date
    ) -> ProviderAccountSnapshot {
        if let previous, previous.observedAt != nil {
            return retained(previous, error: error, now: now)
        }
        return ProviderAccountSnapshot(
            id: id, label: label, windows: [], observedAt: nil, lastError: error, lastAttemptAt: now
        )
    }
    private static func retained(_ previous: ProviderAccountSnapshot, error: String?, now: Date)
        -> ProviderAccountSnapshot
    {
        ProviderAccountSnapshot(
            id: previous.id, label: previous.label, plan: previous.plan,
            subtitle: previous.subtitle,
            windows: previous.windows.map { $0.resolved(asOf: now, isStale: true) },
            balances: previous.balances,
            observedAt: previous.observedAt, isStale: true, lastError: error, lastAttemptAt: now)
    }
}

private struct UnavailableClaudePipeline: ClaudeMeterPipeline {
    func poll(now: Date, kind: RefreshKind) async throws -> ParseResult {
        ParseResult(
            snapshot: nil, warnings: [], errors: [ParseError("Claude usage is unavailable.")])
    }
}

extension MultiAccountOAuth.AccountFetchFailure {
    public var displayText: String {
        switch self {
        case .credentialsMissing: "Credentials missing. Run claude login for this account."
        case .credentialsUnavailable: "Keychain is temporarily unavailable."
        case .credentialsInvalid: "Credentials invalid. Run claude login for this account."
        case .credentialsExpired: "Credentials expired. Run claude login for this account."
        case .unauthorized: "Sign in again with claude login for this account."
        case .rateLimited: "Claude usage is rate limited."
        case .invalidResponse: "Claude returned an invalid usage response."
        case .requestFailed: "Could not refresh Claude usage."
        }
    }
}
