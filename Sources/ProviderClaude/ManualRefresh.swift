import Foundation
import MeterDomain
import MeterPlatform

/// Manual mode: one account, `claude`, read with the app-owned login.
struct ManualRefresh: Sendable {
    static let accountID = ClaudeAccount.defaultID

    let login: ManualLogin
    let api: UsageAPI
    let now: @Sendable () -> Date

    func fetch(previous: ProviderUsage?) async throws -> ProviderUsage {
        if let until = api.gate.blockedUntil(now: now()) {
            throw ProviderError(AccountFailure.rateLimited(until: until).issue(isActiveLogin: true))
        }
        let prior = previous?.account(Self.accountID)
        let slotName = ConfigDirectoryScanner.name(for: Self.accountID)
        let account: AccountUsage
        do {
            var credential = try await login.usable()
            let response: UsageResponse
            do {
                response = try await api.usage(accessToken: credential.accessToken)
            } catch UsageFailure.unauthorized {
                credential = try await login.refreshedAfterRejection(of: credential)
                response = try await api.usage(accessToken: credential.accessToken)
            }
            let after = await login.ownerStatus()
            if after != .unknown, after != .signedIn(credential.owner) {
                Log(.claude).notice("Manual Claude login changed during the usage check")
                account = await failed(after == .signedOut ? .notConnected : .loginChanged, prior)
            } else {
                let observedAt = now()
                account = AccountUsage(
                    id: Self.accountID, name: slotName,
                    plan: ClaudePlan.name(
                        subscriptionType: credential.subscriptionType, rateLimitTier: nil),
                    windows: UsageMapper.windows(response),
                    balances: UsageMapper.balances(response),
                    resetAllowance: UsageMapper.resetAllowance(response),
                    observedAt: observedAt, attemptedAt: observedAt, owner: credential.owner)
            }
        } catch let failure as ManualLogin.Failure {
            account = await failed(AccountFailure(failure), prior)
        } catch let failure as UsageFailure {
            account = await failed(AccountFailure(failure), prior)
        }
        return ProviderUsage(provider: .claude, accounts: [account])
    }

    /// Keeps the account only while its observation belongs to the stored login.
    func reconcile(previous: ProviderUsage) async -> ProviderUsage? {
        guard let account = previous.account(Self.accountID) else { return nil }
        if account.hasObservation, !account.belongs(to: await login.ownerStatus()) {
            return nil
        }
        return ProviderUsage(provider: .claude, accounts: [account])
    }

    private func failed(_ failure: AccountFailure, _ prior: AccountUsage?) async -> AccountUsage {
        failure.account(
            id: Self.accountID, name: ConfigDirectoryScanner.name(for: Self.accountID),
            prior: prior, status: await login.ownerStatus(), isActiveLogin: true, now: now())
    }
}
