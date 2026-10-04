import Foundation
import MeterDomain
import MeterPlatform

/// Automatic mode: reads the Claude Code login of every enabled config dir.
///
/// One account is read on every refresh, and first: the account of Claude Code's active login
/// (see ``Plan/alwaysReadID``). Every other account is read when it has no previous value, or
/// when its previous attempt started at least 290 s before this refresh started; otherwise its
/// previous value is returned unchanged. Requests go out one at a time. Each account has its
/// own deadline inside the budget of the whole refresh, so a slow account cannot discard the
/// others. HTTP 429, or the end of the budget, stops the rest of the refresh; accounts not
/// attempted keep their previous value and `attemptedAt`, so they are due again at the next
/// refresh.
struct AutomaticRefresh: Sendable {
    static let otherAccountInterval: TimeInterval = 300
    /// Refreshes start a little later than the 300 s timer ticks, by a varying amount (local
    /// reads first). Without this margin an account would be read only at every second tick.
    static let dueMargin: TimeInterval = 10
    static let allTurnedOffMessage =
        "Every Claude config dir is turned off. Turn one on in Settings."

    struct Result: Sendable {
        let usage: ProviderUsage
        /// The account of the active login. Nil when the Keychain could not say which it is.
        let activeID: AccountID?
    }

    /// Lists the config dirs. Blocking: called through ``BlockingIO``.
    typealias Scan = @Sendable (_ home: URL, ClaudeConfiguration) -> [ClaudeAccount]

    let home: URL
    let keychain: ClaudeCodeKeychain
    let logins: LoginReader
    let api: UsageAPI
    let now: @Sendable () -> Date
    let limits: ClaudeLimits
    let scan: Scan
    let log = Log(.claude)

    init(
        home: URL, keychain: ClaudeCodeKeychain, logins: LoginReader, api: UsageAPI,
        now: @escaping @Sendable () -> Date, limits: ClaudeLimits,
        scan: @escaping Scan = ConfigDirectoryScanner.discover(home:configuration:)
    ) {
        self.home = home
        self.keychain = keychain
        self.logins = logins
        self.api = api
        self.now = now
        self.limits = limits
        self.scan = scan
    }

    func fetch(_ configuration: ClaudeConfiguration, previous: ProviderUsage?) async throws
        -> Result
    {
        // Each attempted account records this time, so the due check of the next refresh
        // compares the starts of two refreshes, not the end of a slow request.
        let startedAt = now()
        let deadline = ContinuousClock.now + limits.refresh
        let plan = try await plan(configuration)
        if let until = api.gate.blockedUntil(now: now()) {
            throw ProviderError(AccountFailure.rateLimited(until: until).issue(for: .activeLogin))
        }
        // While the Keychain cannot say which login is active, the account of that login has
        // no slot. Its reading stays, marked stale.
        let carried = (previous?.accounts ?? []).filter { account in
            !plan.slots.contains { $0.id == account.id } && plan.mayHoldActiveLogin(account.id)
        }.map { account in
            AccountFailure.credentialsUnavailable.account(
                id: account.id, name: account.name, prior: account, status: .unknown,
                audience: .activeLogin, now: now())
        }
        guard !plan.slots.isEmpty || !carried.isEmpty else {
            if plan.activeLogin == .unknown {
                throw ProviderError(
                    AccountFailure.credentialsUnavailable.issue(for: .activeLogin))
            }
            if !plan.directoryIDs.isEmpty {
                // Config dirs exist, but the user turned every one off.
                throw ProviderError(
                    Self.allTurnedOffMessage, needsAction: true, keepsLastReading: false)
            }
            throw ProviderError(
                AccountFailure.credentialsMissing.issue(for: .activeLogin),
                keepsLastReading: false)
        }

        var fetched: [AccountID: AccountUsage] = [:]
        var identities: [AccountID: LocalIdentity] = [:]
        var stop: AccountFailure?
        for slot in plan.requestOrder {
            let prior = previous?.account(slot.id)
            if let issue = slot.issue {
                fetched[slot.id] = .unavailable(id: slot.id, name: slot.name, issue: issue)
                continue
            }
            let isActive = slot.id == plan.activeID
            guard stop == nil, slot.id == plan.alwaysReadID || isDue(prior, at: startedAt)
            else { continue }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                log.warning("Claude refresh ran out of time before \(slot.id)")
                stop = .timedOut
                continue
            }
            try Task.checkCancellation()
            let outcome = try await fetchAccount(
                slot, prior: prior, isActive: isActive, limit: min(limits.account, remaining))
            var usage = outcome.usage
            usage.attemptedAt = startedAt
            fetched[slot.id] = usage
            identities[slot.id] = outcome.identity
            if case .rateLimited = outcome.failure { stop = outcome.failure }
        }
        for slot in plan.slots where identities[slot.id] == nil && slot.issue == nil {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { break }
            let read = try await logins.identity(
                slot.identityFile, timeout: min(limits.localRead, remaining))
            if case .found(let identity) = read { identities[slot.id] = identity }
        }

        let shared = Self.sharedLogins(identities)
        // An account without a previous value is always due, so only a stop can skip it.
        let skipped =
            stop?.issue(for: .activeLogin) ?? UsageIssue("Claude usage is unavailable.")
        let accounts = plan.slots.map { slot in
            var account =
                fetched[slot.id] ?? previous?.account(slot.id)
                ?? .unavailable(id: slot.id, name: slot.name, issue: skipped)
            account.name = slot.name
            account.sharesLogin = shared.contains(slot.id)
            return account
        }
        return Result(
            usage: ProviderUsage(provider: .claude, accounts: carried + accounts),
            activeID: plan.activeLogin == .unknown ? nil : plan.activeID)
    }

    /// Drops accounts that left the configuration and observations whose login changed.
    /// Local reads only. Keeps `previous` when the config folders cannot be read now.
    func reconcile(_ configuration: ClaudeConfiguration, previous: ProviderUsage) async
        -> ProviderUsage?
    {
        guard let plan = try? await plan(configuration) else { return previous }
        var kept: [AccountUsage] = []
        for account in previous.accounts {
            guard let slot = plan.slots.first(where: { $0.id == account.id }) else {
                if plan.mayHoldActiveLogin(account.id) { kept.append(account) }
                continue
            }
            if account.hasObservation, slot.issue == nil {
                let status = (try? await logins.read(slot))?.status ?? .unknown
                guard account.belongs(to: status) else {
                    log.notice("Claude login changed for \(account.id); dropped its reading")
                    continue
                }
            }
            kept.append(account)
        }
        return kept.isEmpty ? nil : ProviderUsage(provider: .claude, accounts: kept)
    }

    /// Accounts whose `.claude.json` names the same Claude account in the same organization
    /// as another account. One person in two organizations has two quotas, so two logins.
    static func sharedLogins(_ identities: [AccountID: LocalIdentity]) -> Set<AccountID> {
        var accountsByOwner: [AccountOwner: [AccountID]] = [:]
        for (id, identity) in identities {
            guard let owner = identity.owner else { continue }
            accountsByOwner[owner, default: []].append(id)
        }
        return Set(accountsByOwner.values.filter { $0.count > 1 }.joined())
    }

    /// An account is due when it was never attempted, or its last attempt, successful or not,
    /// started at least 290 s before `startedAt`, the start of this refresh: the 300 s
    /// interval less ``dueMargin``. A clock that moved back makes it due.
    private func isDue(_ prior: AccountUsage?, at startedAt: Date) -> Bool {
        guard let attemptedAt = prior?.attemptedAt else { return true }
        let age = startedAt.timeIntervalSince(attemptedAt)
        return age < 0 || age >= Self.otherAccountInterval - Self.dueMargin
    }
}
