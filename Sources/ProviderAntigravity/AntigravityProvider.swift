import Foundation
import MeterDomain
import MeterPlatform

/// Antigravity quota for the login of the Antigravity CLI (`agy`) on this Mac.
///
/// Invokes `agy -p /usage --output-format json` in a private temporary working directory and
/// never reads or modifies Antigravity's credentials. Reports one account,
/// ``AccountID/default``, named "Antigravity". The primary group's 5-hour and weekly windows
/// are binding for the card's severity, while ``ProviderID/canOwnMenuBar`` stays false.
public final class AntigravityProvider: UsageProvider, DiagnosticsReporting {
    /// The account label.
    static let accountName = "Antigravity"
    private static let log = Log(.antigravity)

    private let cli: any AntigravityCLI
    private let now: @Sendable () -> Date
    /// The outcome of the last usage check, for Diagnostics only.
    private let lastRequest = Locked<String?>(nil)

    /// - Parameters:
    ///   - environment: Supplies `ANTIGRAVITY_CLI_PATH` and `PATH`.
    ///   - home: The user's home directory, for locating `agy` in user install folders.
    ///   - now: The clock for observation times.
    public convenience init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            cli: LiveAntigravityCLI(environment: environment, userHome: home),
            now: now)
    }

    init(cli: any AntigravityCLI, now: @escaping @Sendable () -> Date = Date.init) {
        self.cli = cli
        self.now = now
    }

    /// Always ``ProviderID/antigravity``.
    public var id: ProviderID { .antigravity }

    /// Removes the previous reading when `agy` is no longer installed. Checks the filesystem
    /// only and never launches a process.
    public func reconcile(_ previous: ProviderUsage?) async -> ProviderUsage? {
        guard let previous else { return nil }
        do {
            _ = try await cli.locate()
            return previous
        } catch AntigravityFailure.cliNotFound {
            return nil
        } catch {
            return previous
        }
    }

    /// Reads usage for the Antigravity account. Temporary failures keep the previous
    /// observation as stale; a missing CLI or signed-out login drops it. Throws only
    /// `CancellationError`.
    public func fetch(previous: ProviderUsage?) async throws -> ProviderUsage {
        let now = now()
        let previous = previous?.account(.default)
        let account: AccountUsage
        do {
            let command = try await cli.locate()
            let data = try await cli.fetchUsage(using: command)
            let response = try AntigravityUsageResponse(data: data)
            account = response.account(now: now)
            recordRequest(.success(()), at: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as AntigravityFailure {
            if failure != .cliNotFound { recordRequest(.failure(failure), at: now) }
            account = failed(failure, previous: previous, now: now)
        } catch {
            let failure = AntigravityFailure.commandFailed(detail: error.localizedDescription)
            recordRequest(.failure(failure), at: now)
            account = failed(failure, previous: previous, now: now)
        }
        if account.issue == nil, previous?.issue != nil {
            Self.log.notice("Antigravity refresh recovered.")
        }
        return ProviderUsage(provider: .antigravity, accounts: [account])
    }

    /// Where `agy` was found and how the last check ended. Never shows a secret.
    public func diagnostics() async -> [DiagnosticFact] {
        var facts = [
            DiagnosticFact("ANTIGRAVITY_CLI_PATH", cli.usesCustomPath ? "Set" : "Not set")
        ]
        do {
            let command = try await cli.locate()
            facts.append(DiagnosticFact("CLI", command.url.path))
        } catch AntigravityFailure.cliNotFound {
            facts.append(DiagnosticFact("CLI", "Missing"))
        } catch let failure as AntigravityFailure {
            facts.append(DiagnosticFact("CLI", failure.issue.message))
        } catch {
            facts.append(DiagnosticFact("CLI", "Could not look for the Antigravity CLI."))
        }
        facts.append(DiagnosticFact("Last usage request", lastRequest.value ?? "None"))
        return facts
    }

    private func failed(
        _ failure: AntigravityFailure, previous: AccountUsage?, now: Date
    ) -> AccountUsage {
        if previous?.issue != failure.issue {
            Self.log.warning("Antigravity refresh failed: \(failure.issue.message)")
        }
        if let previous, previous.hasObservation, previous.belongs(to: failure.ownerStatus) {
            return previous.retained(issue: failure.issue, now: now)
        }
        return .unavailable(
            id: .default, name: Self.accountName, issue: failure.issue, attemptedAt: now)
    }

    private func recordRequest(_ outcome: Result<Void, AntigravityFailure>, at now: Date) {
        let time = now.formatted(.iso8601)
        lastRequest.withLock {
            switch outcome {
            case .success:
                $0 = "Succeeded at \(time)"
            case .failure(let failure):
                if let detail = failure.diagnosticDetail, !detail.isEmpty {
                    $0 = "Failed at \(time): \(failure.issue.message) Details: \(detail)"
                } else {
                    $0 = "Failed at \(time): \(failure.issue.message)"
                }
            }
        }
    }
}
