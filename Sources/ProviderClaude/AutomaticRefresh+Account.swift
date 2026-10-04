import Foundation
import MeterDomain
import MeterPlatform

extension AutomaticRefresh {
    struct AccountOutcome: Sendable {
        let usage: AccountUsage
        let identity: LocalIdentity?
        let failure: AccountFailure?
    }

    /// Reads one account: credential, one usage request, then the owner again. A response that
    /// arrives after the login changed is discarded. Claude Code's credentials are never
    /// refreshed; an expired token waits for Claude Code to renew it.
    func fetchAccount(_ slot: LoginSlot, prior: AccountUsage?, isActive: Bool) async throws
        -> AccountOutcome
    {
        func failed(_ failure: AccountFailure, _ status: OwnerStatus, _ identity: LocalIdentity?)
            -> AccountOutcome
        {
            let usage = failure.account(
                id: slot.id, name: slot.name, prior: prior, status: status,
                isActiveLogin: isActive, now: now())
            return AccountOutcome(usage: usage, identity: identity, failure: failure)
        }

        let credential: ClaudeCredential
        let owner: AccountOwner
        let identity: LocalIdentity?
        switch try await logins.read(slot) {
        case .failed(let failure, let status):
            return failed(failure, status, nil)
        case .ownerUnknown:
            // Without an owner the response could not be kept safely, so nothing is sent.
            return failed(.identityUnavailable, .unknown, nil)
        case .signedIn(let readCredential, let readOwner, let readIdentity):
            (credential, owner, identity) = (readCredential, readOwner, readIdentity)
        }
        guard !credential.isExpired(at: now()) else {
            return failed(.credentialsExpired, .signedIn(owner), identity)
        }

        let response: UsageResponse
        do {
            response = try await api.usage(accessToken: credential.accessToken)
        } catch let failure as UsageFailure {
            return failed(AccountFailure(failure), .signedIn(owner), identity)
        }

        let after = try await logins.read(slot).status
        if after != .unknown, after != .signedIn(owner) {
            Log(.claude).notice("Claude login changed during the usage check for \(slot.id)")
            return failed(
                after == .signedOut ? .credentialsMissing : .loginChanged, after, identity)
        }
        let observedAt = now()
        let usage = AccountUsage(
            id: slot.id, name: slot.name,
            plan: ClaudePlan.name(
                subscriptionType: credential.subscriptionType,
                rateLimitTier: credential.rateLimitTier ?? identity?.rateLimitTier),
            windows: UsageMapper.windows(response),
            balances: UsageMapper.balances(response),
            resetAllowance: UsageMapper.resetAllowance(response),
            observedAt: observedAt, attemptedAt: observedAt, owner: owner)
        return AccountOutcome(usage: usage, identity: identity, failure: nil)
    }
}
