import Foundation
import MeterDomain
import MeterPlatform

/// Manual mode: one account, `claude`, read with the app-owned login.
struct ManualRefresh: Sendable {
    static let accountID = ClaudeAccount.defaultID

    let login: ManualLogin
    let api: UsageAPI
    let now: @Sendable () -> Date
    let log = Log(.claude)

    func fetch(previous: ProviderUsage?) async throws -> ProviderUsage {
        if let until = api.gate.blockedUntil(now: now()) {
            throw ProviderError(AccountFailure.rateLimited(until: until).issue(for: .manual))
        }
        let prior = previous?.account(Self.accountID)
        let slotName = ConfigDirectoryScanner.name(for: Self.accountID)
        let account: AccountUsage
        do {
            let (credential, response) = try await usage()
            let after = await login.ownerStatus()
            if after != .unknown, after != .signedIn(credential.owner) {
                log.notice("Manual Claude login changed during the usage check")
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

    /// One usage request. After HTTP 401 the refresh token is tried once, and the request is
    /// sent again. HTTP 403 is not refreshed: a refresh does not change the scopes. When the
    /// tokens are still rejected, or a 401 cannot be refreshed, the connection gets no more
    /// requests until the next Connect.
    private func usage() async throws -> (ManualCredential, UsageResponse) {
        let credential = try await login.usable()
        do {
            return (credential, try await api.usage(accessToken: credential.accessToken))
        } catch UsageFailure.unauthorized {
            let refreshed: ManualCredential
            do {
                refreshed = try await login.refreshedAfterRejection(of: credential)
            } catch let failure as ManualLogin.Failure where failure.endsConnection {
                await login.markRejected(credential)
                throw failure
            }
            do {
                return (refreshed, try await api.usage(accessToken: refreshed.accessToken))
            } catch let failure as UsageFailure where failure.isRejection {
                await login.markRejected(refreshed)
                throw failure
            }
        }
    }

    private func failed(_ failure: AccountFailure, _ prior: AccountUsage?) async -> AccountUsage {
        failure.account(
            id: Self.accountID, name: ConfigDirectoryScanner.name(for: Self.accountID),
            prior: prior, status: await login.ownerStatus(), audience: .manual, now: now())
    }
}

extension ManualLogin.Failure {
    /// After HTTP 401, these leave no way to get a working token from the stored login.
    fileprivate var endsConnection: Bool { self == .expired || self == .rejected }
}
