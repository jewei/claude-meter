import ClaudeMeterCore
import Foundation

/// Removes user-disabled Claude accounts from any pipeline result.
///
/// This decorator stays outside the statusline tier. Thus, it also protects the
/// OAuth-to-cache path when the statusline source is off.
public struct DisabledClaudeAccountFilteringPipeline: ClaudeMeterPipeline {
    private let upstream: any ClaudeMeterPipeline
    private let disabledAccountKeys: Set<String>

    public init(
        upstream: any ClaudeMeterPipeline,
        disabledAccountKeys: Set<String>
    ) {
        self.upstream = upstream
        self.disabledAccountKeys = disabledAccountKeys
    }

    public func poll(now: Date, kind: RefreshKind) async throws -> ParseResult {
        let result = try await upstream.poll(now: now, kind: kind)
        let snapshot = result.snapshot.flatMap {
            Self.filteringDisabledAccounts(
                from: $0,
                disabledAccountKeys: disabledAccountKeys)
        }
        return ParseResult(
            snapshot: snapshot,
            warnings: result.warnings,
            errors: result.errors,
            rawHash: result.rawHash,
            parserVersion: result.parserVersion,
            sourceAttempts: result.sourceAttempts
        )
    }

    /// Removes disabled accounts and repairs the top-level active-account mirror.
    /// A lone default account keeps the historical `accounts == nil` shape.
    static func filteringDisabledAccounts(
        from source: ClaudeUsageSnapshot,
        disabledAccountKeys: Set<String>
    ) -> ClaudeUsageSnapshot? {
        guard var accounts = source.accounts else { return source }
        accounts = accounts.filter {
            $0.id == StatuslineBridge.defaultAccountKey
                || !disabledAccountKeys.contains($0.id)
        }

        // The top-level mirror belongs to a named account. If no named account is
        // still enabled, there is no valid snapshot to publish.
        guard !accounts.isEmpty else { return nil }

        let activeIndex = accounts.firstIndex(where: \.isActive) ?? accounts.startIndex
        for index in accounts.indices { accounts[index].isActive = index == activeIndex }
        let active = accounts[activeIndex]

        var snapshot = source
        snapshot.account = active.account
        snapshot.session = active.session
        snapshot.limits = active.limits
        snapshot.lastSuccessfulPollAt = active.lastSuccessfulPollAt
        snapshot.state.severity = active.severity
        snapshot.accounts =
            accounts.count == 1 && active.id == StatuslineBridge.defaultAccountKey
            ? nil : accounts
        return snapshot
    }
}
