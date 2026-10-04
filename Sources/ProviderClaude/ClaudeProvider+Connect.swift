import Foundation
import MeterDomain
import MeterPlatform

extension ClaudeProvider {
    /// Verifies tokens that the user entered with a usage request, then stores them as the
    /// manual login. Throws ``ProviderError`` with text for the user.
    ///
    /// Tokens that expire within 60 s are refreshed first. When the request gets HTTP 401 and
    /// no refresh happened yet, the refresh token is tried once. A refresh never goes out while
    /// the 429 gate is closed, because it spends the pasted refresh token. Tokens that a refresh
    /// got are kept for a retry of Connect until they are stored or rejected. A failure leaves
    /// an existing manual login unchanged, and a Disconnect that starts meanwhile wins.
    public func connectManually(accessToken: String, refreshToken: String?, expiresAt: Date?)
        async throws
    {
        let access = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let pasted = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard !access.isEmpty else {
            throw ProviderError("Enter an access token.", needsAction: true)
        }
        // A Disconnect, or a newer Connect, after this point wins over this Connect.
        let ticket = await manualLogin.beginConnect()
        var candidate = ManualCredential(
            accessToken: access, refreshToken: pasted, expiresAt: expiresAt,
            subscriptionType: nil, connectionID: UUID().uuidString)
        var isRefreshed = false
        // An earlier Connect may have spent the pasted refresh token already.
        if let pasted, let pending = await manualLogin.pendingRotation(for: pasted) {
            candidate = pending
            isRefreshed = true
        }
        if candidate.isExpired(at: now()) {
            candidate = try await refreshedForConnect(candidate, pasted: pasted)
            isRefreshed = true
        }
        do {
            try await checkUsage(accessToken: candidate.accessToken)
        } catch UsageFailure.unauthorized where !isRefreshed && pasted != nil {
            // The access token is stale although no expiry said so. The refresh token can
            // still work.
            candidate = try await refreshedForConnect(candidate, pasted: pasted)
            try await checkRefreshed(candidate, pasted: pasted)
        } catch is UsageFailure {
            if isRefreshed, let pasted { await manualLogin.discardPendingRotation(for: pasted) }
            throw Self.tokensRejected
        }
        do {
            try await manualLogin.connect(candidate, ticket: ticket)
        } catch ManualLogin.Failure.changed {
            throw ProviderError(
                "The Claude connection changed while the tokens were checked. Try again.")
        } catch {
            throw ProviderError("Could not save credentials: \(error.localizedDescription)")
        }
    }

    /// Whether a manual login is stored. Reads item attributes only.
    public func manualSignInStatus() async -> SignInStatus {
        await vault.signInStatus()
    }

    /// Deletes the manual login, the only item the app owns, and forgets its tokens. A fetch,
    /// refresh, or Connect that is still running can never write it back. Deleting a missing
    /// item succeeds, so Settings can call this in every mode.
    public func disconnectManual() async throws {
        do {
            try await manualLogin.disconnect()
        } catch {
            throw ProviderError("Could not disconnect: \(error.localizedDescription)")
        }
    }

    private static let tokensRejected = ProviderError(
        "Anthropic rejected these tokens. Check them and try again.", needsAction: true)

    private func refreshedForConnect(_ candidate: ManualCredential, pasted: String?)
        async throws -> ManualCredential
    {
        guard let pasted else {
            throw ProviderError(
                "The access token has expired. Enter a new one, or add a refresh token.",
                needsAction: true)
        }
        // The usage check after the refresh could not run while the gate is closed, and the
        // refresh would spend the pasted token for nothing.
        if let until = gate.blockedUntil(now: now()) { throw rateLimited(until: until) }
        do {
            return try await manualLogin.refreshedCandidate(candidate, pastedRefreshToken: pasted)
        } catch ManualLogin.Failure.rejected {
            throw ProviderError(
                "Anthropic rejected the refresh token. Enter new tokens.", needsAction: true)
        } catch ManualLogin.Failure.refreshFailed(let reason) {
            throw ProviderError("Could not refresh the tokens. \(reason) Try again shortly.")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError(wrapping: error)
        }
    }

    /// The usage check after a refresh. Rejected tokens are forgotten.
    private func checkRefreshed(_ candidate: ManualCredential, pasted: String?) async throws {
        do {
            try await checkUsage(accessToken: candidate.accessToken)
        } catch is UsageFailure {
            if let pasted { await manualLogin.discardPendingRotation(for: pasted) }
            throw Self.tokensRejected
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
