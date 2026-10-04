import Foundation
import MeterDomain
import MeterPlatform

extension ClaudeProvider {
    /// Every config dir for `configuration`, enabled and disabled, default first. Settings
    /// lists them and token history scans them.
    ///
    /// - Throws: `CancellationError`, or a ``ProviderError`` when the home folder cannot be
    ///   listed, or the folders cannot be listed in 5 s. Callers keep what they had: a slow
    ///   disk must never look like "no config dirs", which would empty the Settings list and
    ///   discard the history scan state.
    public func accounts(for configuration: ClaudeConfiguration) async throws -> [ClaudeAccount] {
        try await automatic.discover(configuration)
    }

    /// The canonical form of `url` (standardized, symbolic links resolved) when it is a config
    /// dir: a directory that holds `settings.json` or `projects`. Nil when it is not one, or
    /// when the check takes more than 5 s, for example on a stuck network volume. The file
    /// calls run off the caller's thread, so Settings can call this from the main actor.
    public static func configDirectory(at url: URL) async -> URL? {
        let checked = try? await BlockingIO.run(timeout: ClaudeLimits().localRead) { _ in
            // The form that discovery uses for ``ClaudeAccount/canonicalPath``.
            let canonical = URL(
                fileURLWithPath: ConfigDirectoryScanner.canonicalPath(url), isDirectory: true)
            return ConfigDirectoryScanner.isConfigDirectory(canonical) ? canonical : nil
        }
        return checked ?? nil
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
            do {
                try await checkUsage(accessToken: credential.accessToken)
            } catch is UsageFailure {
                throw ProviderError(
                    "Anthropic rejected Claude Code's sign-in. Open Claude Code and run /login, "
                        + "then try again.",
                    needsAction: true)
            }
        }
    }

    /// The end of the HTTP 429 block, or nil when usage requests may go out.
    public func rateLimitedUntil() async -> Date? {
        gate.blockedUntil(now: now())
    }

    /// The Keychain did not answer: it may be locked, slow, or need an approval that the app
    /// never asks for, so the text names no single cause.
    private static let keychainUnavailable = ProviderError(
        "The Keychain did not answer. If your Mac is locked, unlock it, then try again.")

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

    /// One usage request for Settings. Rethrows HTTP 401 and 403 as ``UsageFailure``, so the
    /// caller can choose the text or try a refresh token. Every other failure becomes a
    /// ``ProviderError`` with text for Settings.
    func checkUsage(accessToken: String) async throws {
        do {
            _ = try await withDeadline(limits.refresh) { [api] in
                try await api.usage(accessToken: accessToken)
            }
        } catch let failure as UsageFailure {
            switch failure {
            case .unauthorized, .forbidden: throw failure
            case .rateLimited(let until): throw rateLimited(until: until)
            default: throw ProviderError(AccountFailure(failure).issue(for: .activeLogin))
            }
        } catch let error as TimeoutError {
            throw ProviderError("Could not check Claude usage. \(error.localizedDescription)")
        }
    }
}
