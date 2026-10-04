import Foundation
import MeterDomain
import MeterPlatform

/// Automatic mode: reads the Claude Code login of every enabled config dir.
///
/// The account of Claude Code's active login is read on every refresh. Every other account is
/// read when the previous value has no observation or was attempted at least 300 s ago;
/// otherwise its previous value is returned unchanged. Requests go out one at a time. HTTP 429
/// stops the rest of the refresh; accounts not attempted keep their previous value and
/// `attemptedAt`, so they are due again as soon as the gate opens.
struct AutomaticRefresh: Sendable {
    static let otherAccountInterval: TimeInterval = 300

    struct Plan: Sendable, Equatable {
        /// Output order: an unmapped active login first, then config dirs in discovery order.
        var slots: [LoginSlot]
        /// The account of Claude Code's active login, or `claude` when there is none.
        var activeID: AccountID
    }

    struct Result: Sendable {
        let usage: ProviderUsage
        let activeID: AccountID
    }

    let home: URL
    let keychain: ClaudeCodeKeychain
    let logins: LoginReader
    let api: UsageAPI
    let now: @Sendable () -> Date
    let discoveryTimeout: Duration
    private let log = Log(.claude)

    init(
        home: URL, keychain: ClaudeCodeKeychain, logins: LoginReader, api: UsageAPI,
        now: @escaping @Sendable () -> Date, discoveryTimeout: Duration
    ) {
        self.home = home
        self.keychain = keychain
        self.logins = logins
        self.api = api
        self.now = now
        self.discoveryTimeout = discoveryTimeout
    }

    /// Discovers config dirs and maps Claude Code's active Keychain item to one of them.
    func plan(_ configuration: ClaudeConfiguration) async throws -> Plan {
        let home = home
        let accounts: [ClaudeAccount]
        do {
            accounts = try await BlockingIO.run(timeout: discoveryTimeout) { _ in
                ConfigDirectoryScanner.discover(home: home, configuration: configuration)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError(
                "Could not read the Claude config folders. \(error.localizedDescription)")
        }
        let activeService: String?
        do {
            activeService = try await keychain.activeService()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            activeService = nil
        }

        var slots = accounts.filter(\.isEnabled).map { LoginSlot(account: $0, home: home) }
        var activeID = ClaudeAccount.defaultID
        if let service = activeService {
            // A disabled account can own the active login; it then has no slot and no card.
            if let owner = accounts.first(where: {
                ClaudeCodeKeychain.services(for: $0).contains(service)
            }) {
                activeID = owner.id
            } else if service == ClaudeCodeKeychain.legacyService {
                slots.insert(.legacyDefault, at: 0)
            } else {
                let unmapped = LoginSlot(unmappedService: service)
                slots.insert(unmapped, at: 0)
                activeID = unmapped.id
            }
        }
        return Plan(slots: slots, activeID: activeID)
    }

    func fetch(_ configuration: ClaudeConfiguration, previous: ProviderUsage?) async throws
        -> Result
    {
        let plan = try await plan(configuration)
        if let until = api.gate.blockedUntil(now: now()) {
            throw ProviderError(AccountFailure.rateLimited(until: until).issue(isActiveLogin: true))
        }
        guard !plan.slots.isEmpty else {
            throw ProviderError(
                AccountFailure.credentialsMissing.issue(isActiveLogin: true),
                keepsLastReading: false)
        }

        var fetched: [AccountID: AccountUsage] = [:]
        var identities: [AccountID: LocalIdentity] = [:]
        var stop: AccountFailure?
        for slot in plan.slots {
            let prior = previous?.account(slot.id)
            if let issue = slot.issue {
                fetched[slot.id] = .unavailable(id: slot.id, name: slot.name, issue: issue)
                continue
            }
            guard stop == nil, slot.id == plan.activeID || isDue(prior) else { continue }
            try Task.checkCancellation()
            let outcome = try await fetchAccount(
                slot, prior: prior, isActive: slot.id == plan.activeID)
            fetched[slot.id] = outcome.usage
            identities[slot.id] = outcome.identity
            if case .rateLimited = outcome.failure { stop = outcome.failure }
        }
        for slot in plan.slots where identities[slot.id] == nil && slot.issue == nil {
            identities[slot.id] = await logins.identity(slot.identityFile)
        }

        let shared = Self.sharedLogins(identities)
        // An account without a previous value is always due, so only a 429 can skip it.
        let skipped =
            stop?.issue(isActiveLogin: false) ?? UsageIssue("Claude usage is unavailable.")
        let accounts = plan.slots.map { slot in
            var account =
                fetched[slot.id] ?? previous?.account(slot.id)
                ?? .unavailable(id: slot.id, name: slot.name, issue: skipped)
            account.name = slot.name
            account.sharesLogin = shared.contains(slot.id)
            return account
        }
        return Result(
            usage: ProviderUsage(provider: .claude, accounts: accounts), activeID: plan.activeID)
    }

    /// Drops accounts that left the configuration and observations whose login changed.
    /// Local reads only. Keeps `previous` when the config folders cannot be read now.
    func reconcile(_ configuration: ClaudeConfiguration, previous: ProviderUsage) async
        -> ProviderUsage?
    {
        guard let plan = try? await plan(configuration) else { return previous }
        var kept: [AccountUsage] = []
        for account in previous.accounts {
            guard let slot = plan.slots.first(where: { $0.id == account.id }) else { continue }
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

    /// Accounts whose `.claude.json` names the same Claude account as another account.
    static func sharedLogins(_ identities: [AccountID: LocalIdentity]) -> Set<AccountID> {
        var accountsByLogin: [String: [AccountID]] = [:]
        for (id, identity) in identities {
            guard let uuid = identity.accountUUID, !uuid.isEmpty else { continue }
            accountsByLogin[uuid, default: []].append(id)
        }
        return Set(accountsByLogin.values.filter { $0.count > 1 }.joined())
    }

    private func isDue(_ prior: AccountUsage?) -> Bool {
        guard let prior, prior.hasObservation, let attemptedAt = prior.attemptedAt else {
            return true
        }
        let age = now().timeIntervalSince(attemptedAt)
        return age < 0 || age >= Self.otherAccountInterval
    }
}
