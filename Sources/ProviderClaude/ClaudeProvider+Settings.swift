import Foundation
import MeterDomain
import MeterPlatform

extension ClaudeProvider {
    /// Every config dir for `configuration`, enabled and disabled, default first. Settings
    /// lists them and token history scans them. Empty when the folders cannot be listed in 5 s.
    public func accounts(for configuration: ClaudeConfiguration) async -> [ClaudeAccount] {
        let home = home
        return
            (try? await BlockingIO.run(timeout: limits.discovery) { _ in
                ConfigDirectoryScanner.discover(home: home, configuration: configuration)
            }) ?? []
    }

    /// Whether `url` is a directory that holds `settings.json` or `projects`. Settings checks
    /// this before it adds a config dir.
    public static func isConfigDirectory(_ url: URL) -> Bool {
        ConfigDirectoryScanner.isConfigDirectory(url)
    }

    /// Whether Claude Code has a login in the Keychain. Reads item attributes only, never a
    /// secret, so Settings can call it before the user confirms Connect. A locked Keychain
    /// gives `.unknown`.
    public func automaticSignInStatus() async -> SignInStatus {
        do {
            return try await keychain.activeService() == nil ? .signedOut : .signedIn
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Checks automatic mode after the user confirmed Connect: reads Claude Code's active
    /// credential and sends one usage request. Throws ``ProviderError`` with text for the user.
    public func verifyAutomaticConnection() async throws {
        let service: String?
        do {
            service = try await keychain.activeService()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.keychainUnavailable
        }
        let notFound = ProviderError(AccountFailure.credentialsMissing.issue(for: .activeLogin))
        guard let service else { throw notFound }
        switch try await keychain.credential(services: [service]) {
        case .missing:
            throw notFound
        case .invalid:
            throw ProviderError(AccountFailure.credentialsInvalid.issue(for: .activeLogin))
        case .unavailable:
            throw Self.keychainUnavailable
        case .found(let credential):
            // Claude Code renews its own token; the app never does.
            guard !credential.isExpired(at: now()) else {
                throw ProviderError(
                    "Claude Code's token expired. Open Claude Code, then try again.",
                    needsAction: true)
            }
            try await verify(
                accessToken: credential.accessToken,
                rejection: ProviderError(
                    "Anthropic rejected Claude Code's sign-in. Open Claude Code and run /login, "
                        + "then try again.",
                    needsAction: true))
        }
    }

    /// Verifies tokens that the user entered with one usage request, then stores them as the
    /// manual login. Tokens that expire within 60 s are refreshed first. A failure leaves an
    /// existing manual login unchanged. Throws ``ProviderError`` with text for the user.
    public func connectManually(accessToken: String, refreshToken: String?, expiresAt: Date?)
        async throws
    {
        let access = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty else {
            throw ProviderError("Enter an access token.", needsAction: true)
        }
        var candidate = ManualCredential(
            accessToken: access, refreshToken: refresh?.isEmpty == false ? refresh : nil,
            expiresAt: expiresAt, subscriptionType: nil, connectionID: UUID().uuidString)
        if candidate.isExpired(at: now()) {
            do {
                candidate = try await manualLogin.refreshedCandidate(candidate)
            } catch ManualLogin.Failure.expired {
                throw ProviderError(
                    "The access token has expired. Enter a new one, or add a refresh token.",
                    needsAction: true)
            } catch ManualLogin.Failure.rejected {
                throw ProviderError(
                    "Anthropic rejected the refresh token. Enter new tokens.", needsAction: true)
            } catch ManualLogin.Failure.refreshFailed(let reason) {
                throw ProviderError("Could not refresh the tokens. \(reason) Try again shortly.")
            }
        }
        try await verify(
            accessToken: candidate.accessToken,
            rejection: ProviderError(
                "Anthropic rejected these tokens. Check them and try again.", needsAction: true))
        do {
            try await manualLogin.connect(candidate)
        } catch {
            throw ProviderError("Could not save credentials: \(error.localizedDescription)")
        }
    }

    /// Whether a manual login is stored. Reads item attributes only.
    public func manualSignInStatus() async -> SignInStatus {
        await vault.signInStatus()
    }

    /// Deletes the manual login, the only item the app owns. A refresh that is still running
    /// can never write it back.
    public func disconnectManual() async throws {
        do {
            try await manualLogin.disconnect()
        } catch {
            throw ProviderError("Could not disconnect: \(error.localizedDescription)")
        }
    }

    /// The end of the HTTP 429 block, or nil when usage requests may go out.
    public func rateLimitedUntil() async -> Date? {
        gate.blockedUntil(now: now())
    }

    private static let keychainUnavailable = ProviderError(
        "Keychain access is unavailable. Unlock your Mac and try again.")

    /// Settings does not retry, so the text says when the user can.
    func rateLimited(until: Date?) -> ProviderError {
        let wait = until.map { Self.waitText(seconds: $0.timeIntervalSince(now())) } ?? "later"
        return ProviderError(
            "\(AccountFailure.rateLimitedMessage) Try again \(wait).", retryAt: until)
    }

    /// "in 3 min", "in 2 h", or "in 1 h 5 min", rounded up to whole minutes.
    static func waitText(seconds: TimeInterval) -> String {
        let minutes = max(1, Int((max(0, seconds) / 60).rounded(.up)))
        guard minutes >= 60 else { return "in \(minutes) min" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    private func verify(accessToken: String, rejection: ProviderError) async throws {
        do {
            _ = try await withDeadline(limits.refresh) { [api] in
                try await api.usage(accessToken: accessToken)
            }
        } catch UsageFailure.unauthorized {
            throw rejection
        } catch UsageFailure.rateLimited(let until) {
            throw rateLimited(until: until)
        } catch let failure as UsageFailure {
            throw ProviderError(AccountFailure(failure).issue(for: .activeLogin))
        } catch let error as TimeoutError {
            throw ProviderError("Could not check Claude usage. \(error.localizedDescription)")
        }
    }
}
