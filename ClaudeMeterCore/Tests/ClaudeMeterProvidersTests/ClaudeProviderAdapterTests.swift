import ClaudeMeterCore
import Foundation
import Testing

@testable import ClaudeMeterProviders

private actor ClaudeFetchFixture {
    var primaryFails = false
    var secondaryFails: Set<String> = []
    var primaryUsed = 20.0
    private(set) var secondaryCalls: [[String]] = []
    func failures(primary: Bool, secondary: Set<String> = []) {
        primaryFails = primary
        secondaryFails = secondary
    }
    func usage(_ value: Double) { primaryUsed = value }
    func primary(now: Date) -> ParseResult {
        if primaryFails {
            return ParseResult(
                snapshot: nil, warnings: [], errors: [ParseError("Offline")],
                oauthAccountKey: "claude",
                sourceAttempts: [.init(source: .oauth, outcome: .failed, reason: .networkError)])
        }
        let account = AccountUsage(
            id: "claude", label: "Personal",
            account: AccountInfo(organization: "personal", email: "user@example.test", plan: "Pro"),
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: primaryUsed, resetsAt: now.addingTimeInterval(3600)),
                currentWeekAllModels: LimitWindow(
                    percentUsed: 10, resetsAt: now.addingTimeInterval(86400)),
                currentWeekOpus: LimitWindow(percentUsed: 40),
                scopedWeekly: [
                    ScopedLimitWindow(id: "seven_day_sonnet", window: LimitWindow(percentUsed: 80))
                ],
                extraUsage: ExtraUsage(
                    isEnabled: true, usedCredits: 1234, monthlyLimit: 5000, currency: "USD")),
            lastSuccessfulPollAt: now, severity: .normal)
        return ParseResult(
            snapshot: ClaudeUsageSnapshot(
                parserVersion: "oauth-api-1.0", createdAt: now,
                lastSuccessfulPollAt: now, source: SourceInfo(cliPath: "test", command: "usage"),
                limits: account.limits, state: SnapshotState(status: .ok, severity: .normal),
                accounts: [account]),
            warnings: [], errors: [], oauthAccountKey: "claude",
            sourceAttempts: [.init(source: .oauth, outcome: .selected, reason: .freshData)])
    }
    func secondary(_ accounts: [AccountConfig], now: Date) -> [MultiAccountOAuth.AccountFetchResult]
    {
        secondaryCalls.append(accounts.map(\.id))
        return accounts.map {
            if secondaryFails.contains($0.id) {
                return .init(accountKey: $0.id, reading: nil, failure: .requestFailed)
            }
            return .init(
                accountKey: $0.id,
                reading: OAuthAccountReading(
                    accountKey: $0.id, label: $0.label,
                    email: nil, plan: "Max", organizationId: $0.id,
                    limits: LimitInfo(currentSession: LimitWindow(percentUsed: 70)),
                    severity: .normal, fetchedAt: now), failure: nil)
        }
    }
}

private actor ClaudeFetchGate {
    var pending: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }
    func wait() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        pending?.resume()
        pending = nil
    }
}

@MainActor
private final class ClaudeConfigurationFixture {
    var value = ClaudeConfiguration(mode: "auto")
}

@Suite("Claude provider lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct ClaudeProviderAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let accounts = ["claude", "claude-work", "claude-other"].map {
        AccountConfig(id: $0, label: $0, configDir: URL(fileURLWithPath: "/test/\($0)"))
    }
    private func isolated(_ body: (URL) async throws -> Void) async rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClaudeAdapter-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
    private func provider(_ directory: URL, fixture: ClaudeFetchFixture, multiple: Bool = true)
        -> ClaudeProviderAdapter
    {
        let accounts = multiple ? accounts : Array(accounts.prefix(1))
        return ClaudeProviderAdapter(
            configuration: { .init(mode: "auto") }, directory: directory,
            discover: { _ in accounts }, primary: { _, _, now in await fixture.primary(now: now) },
            secondary: { accounts, _, now in await fixture.secondary(accounts, now: now) })
    }
    private func refresh(
        _ provider: ClaudeProviderAdapter, previous: ProviderSnapshot? = nil, at date: Date? = nil
    ) async throws -> ProviderSnapshot {
        let id = UUID()
        let date = date ?? now
        let valid = try await provider.validatePrevious(previous, now: date, refreshID: id)
        let result = try await provider.fetch(now: date, previous: valid, refreshID: id)
        provider.didAccept(result, refreshID: id)
        await provider.waitForPersistence()
        return result
    }

    @Test("Single OAuth account succeeds, retains stale data on failure, and recovers")
    func singleAccount() async throws {
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            let provider = provider(directory, fixture: fixture, multiple: false)
            let first = try await refresh(provider)
            #expect(first.accounts.count == 1)
            #expect(first.accounts[0].plan == "Pro")
            #expect(first.accounts[0].windows.map(\.id).contains("seven_day_sonnet"))
            #expect(first.accounts[0].balances[0].value == Decimal(string: "12.34"))
            await fixture.failures(primary: true)
            let stale = try await refresh(provider, previous: first, at: now.addingTimeInterval(60))
            #expect(stale.accounts[0].isStale)
            #expect(stale.accounts[0].observedAt == now)
            #expect(stale.accounts[0].lastError == "Offline")
            await fixture.failures(primary: false)
            let fresh = try await refresh(
                provider, previous: stale, at: now.addingTimeInterval(120))
            #expect(!fresh.accounts[0].isStale)
            #expect(fresh.accounts[0].lastError == nil)
            #expect(fresh.accounts[0].observedAt == now.addingTimeInterval(120))
        }
    }

    @Test("Failure without previous data keeps an unavailable account and accepted error")
    func unavailable() async throws {
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            await fixture.failures(primary: true)
            let provider = provider(directory, fixture: fixture, multiple: false)
            let result = try await refresh(provider)
            #expect(result.accounts.count == 1)
            #expect(result.accounts[0].observedAt == nil)
            #expect(result.accounts[0].windows.isEmpty)
            let error = try SnapshotStore(directory: directory).readLastError()
            #expect(error?.message == "Offline")
            #expect(try SnapshotStore(directory: directory).readLatest() == nil)
        }
    }

    @Test("Mixed account freshness and failures stay independent", arguments: [false, true])
    func mixed(primaryFails: Bool) async throws {
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            let provider = provider(directory, fixture: fixture)
            let first = try await refresh(provider)
            #expect(first.accounts.map(\.id) == accounts.map(\.id))
            await fixture.failures(
                primary: primaryFails, secondary: primaryFails ? [] : ["claude-work"])
            let next = try await refresh(provider, previous: first, at: now.addingTimeInterval(301))
            #expect(next.accounts[0].isStale == primaryFails)
            #expect(next.accounts[1].isStale == !primaryFails)
            #expect(!next.accounts[2].isStale)
            #expect(next.accounts[primaryFails ? 0 : 1].observedAt == now)
        }
    }

    @Test("Unavailable configured accounts remain visible; all unavailable has no observation")
    func partialUnavailable() async throws {
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            await fixture.failures(primary: false, secondary: ["claude-work", "claude-other"])
            let result = try await refresh(provider(directory, fixture: fixture))
            #expect(result.accounts[0].observedAt == now)
            #expect(result.accounts[1].observedAt == nil)
            #expect(result.accounts[1].lastError != nil)
        }
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            await fixture.failures(primary: true, secondary: ["claude-work", "claude-other"])
            let result = try await refresh(provider(directory, fixture: fixture))
            #expect(result.accounts.allSatisfy { $0.observedAt == nil && $0.lastError != nil })
        }
    }

    @Test("Secondary cadence reuses the original observation and retries when due")
    func cadence() async throws {
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            let provider = provider(directory, fixture: fixture)
            let first = try await refresh(provider)
            let reused = try await refresh(
                provider, previous: first, at: now.addingTimeInterval(60))
            #expect(await fixture.secondaryCalls.count == 1)
            #expect(reused.accounts[1].observedAt == now)
            #expect(reused.accounts[0].observedAt == now.addingTimeInterval(60))
            let next = try await refresh(
                provider, previous: reused, at: now.addingTimeInterval(300))
            #expect(await fixture.secondaryCalls.count == 2)
            #expect(next.accounts[1].observedAt == now.addingTimeInterval(300))
        }
    }

    @Test("A secondary failure stays in diagnostics while its next request is not due")
    func retainedFailureDiagnostics() async throws {
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            await fixture.failures(primary: false, secondary: ["claude-work"])
            let provider = provider(directory, fixture: fixture)
            let first = try await refresh(provider)
            let reused = try await refresh(
                provider, previous: first, at: now.addingTimeInterval(60))
            #expect(provider.diagnostics.accountFailures["claude-work"] == .requestFailed)
            #expect(reused.accounts[1].lastAttemptAt == now)
            await fixture.failures(primary: false)
            _ = try await refresh(provider, previous: reused, at: now.addingTimeInterval(300))
            #expect(provider.diagnostics.accountFailures.isEmpty)
        }
    }

    @Test("Disabled accounts disappear before fetch and a mode change rejects previous data")
    func configuration() async throws {
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            let config = ClaudeConfigurationFixture()
            let accounts = accounts
            let provider = ClaudeProviderAdapter(
                configuration: { config.value }, directory: directory,
                discover: { _ in accounts },
                primary: { _, _, now in await fixture.primary(now: now) },
                secondary: { accounts, _, now in await fixture.secondary(accounts, now: now) })
            let first = try await refresh(provider)
            config.value = .init(mode: "auto", disabledKeys: ["claude", "claude-work"])
            let valid = try await provider.validatePrevious(first, now: now, refreshID: UUID())
            #expect(valid?.accounts.map(\.id) == ["claude", "claude-other"])
            config.value = .init(mode: "manual")
            #expect(try await provider.validatePrevious(first, now: now, refreshID: UUID()) == nil)
        }
    }

    @Test("Disabled primary identity cannot return under a different key")
    func disabledPrimary() async throws {
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            let accounts = accounts
            let provider = ClaudeProviderAdapter(
                configuration: { .init(mode: "auto", disabledKeys: ["claude-work"]) },
                directory: directory, discover: { _ in accounts },
                primary: { _, discovered, now in
                    #expect(discovered.contains { $0.id == "claude-work" })
                    let result = await fixture.primary(now: now)
                    var snapshot = result.snapshot
                    snapshot?.accounts?[0].id = "claude-work"
                    return ParseResult(
                        snapshot: snapshot, warnings: [], errors: [], oauthAccountKey: "claude-work"
                    )
                }, secondary: { accounts, _, now in await fixture.secondary(accounts, now: now) })
            let result = try await refresh(provider)
            #expect(result.accounts.map(\.id) == ["claude", "claude-other"])
            #expect(result.accounts.allSatisfy { $0.observedAt == now })
        }
    }

    @Test("Raw request errors are sanitized before entering normalized accounts")
    func sanitizedFailure() async throws {
        try await isolated { directory in
            let provider = ClaudeProviderAdapter(
                configuration: { .init(mode: "manual") }, directory: directory,
                discover: { _ in [] },
                primary: { _, _, _ in
                    ParseResult(
                        snapshot: nil, warnings: [],
                        errors: [
                            ParseError("Failed for private@example.com at /Users/private/.claude")
                        ])
                }, secondary: { _, _, _ in [] })
            let result = try await refresh(provider)
            let error = try #require(result.accounts[0].lastError)
            #expect(!error.contains("private@example.com"))
            #expect(!error.contains("/Users/private"))
        }
    }

    @Test("Accepted archives restore stale, with original account keys, windows and balances")
    func persistence() async throws {
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            let first = try await refresh(provider(directory, fixture: fixture))
            let replacement = provider(directory, fixture: fixture)
            #expect(await replacement.hasPersistedObservation())
            let restored = try #require(
                try await replacement.validatePrevious(nil, now: now, refreshID: UUID()))
            #expect(restored.accounts.map(\.id) == first.accounts.map(\.id))
            #expect(restored.accounts.allSatisfy { $0.isStale })
            #expect(restored.accounts[0].balances == first.accounts[0].balances)
            #expect(restored.accounts[0].observedAt == first.accounts[0].observedAt)
            let selected = ProviderAccountSelection.primary(
                from: restored.accounts, pinnedAccountID: "claude-work", asOf: now)
            #expect(selected?.id == "claude-work")
            #expect(
                ProviderAccountSelection.primary(
                    from: restored.accounts, pinnedAccountID: "missing", asOf: now) == nil)
            #expect(
                ProviderAccountSelection.primary(
                    from: restored.accounts, pinnedAccountID: nil, asOf: now)?.id == "claude-work")
        }
    }

    @Test("Legacy top-level observations remain stale and expired windows become unknown")
    func oldSnapshot() async throws {
        try await isolated { directory in
            let old = ClaudeUsageSnapshot(
                parserVersion: "statusline-1.0", createdAt: now.addingTimeInterval(-600),
                source: SourceInfo(cliPath: "legacy", command: "legacy"),
                limits: LimitInfo(
                    currentSession: LimitWindow(
                        percentUsed: 90, resetsAt: now.addingTimeInterval(-1))),
                state: SnapshotState(status: .ok, severity: .critical))
            try SnapshotStore(directory: directory).writeLatest(old)
            let fixture = ClaudeFetchFixture()
            let provider = provider(directory, fixture: fixture, multiple: false)
            let restored = try #require(
                try await provider.validatePrevious(nil, now: now, refreshID: UUID()))
            #expect(restored.accounts[0].isStale)
            #expect(restored.accounts[0].windows[0].usedPercent == nil)
            #expect(restored.accounts[0].windows[0].resetAt == nil)
            _ = try await refresh(provider, previous: restored)
            #expect(
                try SnapshotStore(directory: directory).readLatest()?.parserVersion
                    == "oauth-api-1.0")
        }
    }

    @Test("An obsolete fetch cannot stage or persist over an accepted newer result")
    func supersession() async throws {
        try await isolated { directory in
            let fixture = ClaudeFetchFixture()
            let gate = ClaudeFetchGate()
            let accounts = accounts
            let firstDate = now
            let provider = ClaudeProviderAdapter(
                configuration: { .init(mode: "auto") }, directory: directory,
                discover: { _ in accounts },
                primary: { _, _, now in
                    if now == firstDate { await gate.suspend() }
                    return await fixture.primary(now: now)
                }, secondary: { _, _, _ in [] })
            let oldID = UUID()
            let valid = try await provider.validatePrevious(nil, now: now, refreshID: oldID)
            let old = Task { try await provider.fetch(now: now, previous: valid, refreshID: oldID) }
            await gate.wait()
            let current = try await refresh(provider, at: now.addingTimeInterval(60))
            await gate.release()
            do {
                _ = try await old.value
                Issue.record("Obsolete fetch was accepted")
            } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
            provider.didAccept(current, refreshID: oldID)
            await provider.waitForPersistence()
            #expect(
                try SnapshotStore(directory: directory).readLatest()?.lastSuccessfulPollAt
                    == now.addingTimeInterval(60))
        }
    }
    @Test("Queued archive writes leave MainActor free and preserve acceptance order")
    func orderedWrites() async {
        await isolated { directory in
            let queue = DispatchQueue(label: "ClaudePersistenceTest")
            queue.suspend()
            let archive = ClaudeReadingStore(directory: directory, queue: queue)
            let fixture = ClaudeFetchFixture()
            let first = await fixture.primary(now: now).snapshot
            let next = now.addingTimeInterval(60)
            let second = await fixture.primary(now: next).snapshot
            archive.enqueue(first, error: nil)
            archive.enqueue(second, error: nil)
            var finished = false
            let waiting = Task {
                await archive.waitForWrites()
                finished = true
            }
            await Task { @MainActor in
                #expect(!finished)
                #expect(
                    !FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("current.json").path))
            }.value
            waiting.cancel()  // Accepted writes are not revoked by cancellation.
            queue.resume()
            await waiting.value
            #expect(finished)
            let restored = await archive.read()
            #expect(restored?.lastSuccessfulPollAt == next)
        }
    }

    @Test("A new account observation clears optional fields")
    func completeReplacement() async throws {
        try await isolated { directory in
            // The request counter is actor-isolated inside this small fixture.
            let gate = ReplacementFixture()
            let provider = ClaudeProviderAdapter(
                configuration: { .init(mode: "manual") }, directory: directory,
                discover: { _ in [] }, primary: { _, _, now in await gate.result(now: now) },
                secondary: { _, _, _ in [] })
            let first = try await refresh(provider)
            let next = try await refresh(provider, previous: first, at: now.addingTimeInterval(60))
            #expect(first.accounts[0].plan == "Max")
            #expect(next.accounts[0].plan == nil)
            #expect(next.accounts[0].windows.first?.usedPercent == nil)
            #expect(next.accounts[0].balances.isEmpty)
            #expect(!next.accounts[0].windows.contains { $0.id == "seven_day_opus" })
        }
    }

}

private actor ReplacementFixture {
    private var calls = 0
    func result(now: Date) -> ParseResult {
        calls += 1
        let optional = calls == 1
        let raw = ClaudeUsageSnapshot(
            parserVersion: "oauth-api-1.0", createdAt: now, lastSuccessfulPollAt: now,
            source: SourceInfo(cliPath: "test", command: "usage"),
            account: AccountInfo(plan: optional ? "Max" : nil),
            limits: LimitInfo(
                currentSession: LimitWindow(percentUsed: nil),
                currentWeekOpus: optional ? LimitWindow(percentUsed: 90) : nil,
                extraUsage: optional ? ExtraUsage(isEnabled: true, usedCredits: 100) : nil),
            state: SnapshotState(status: .ok, severity: .normal))
        return ParseResult(snapshot: raw, warnings: [], errors: [], oauthAccountKey: "claude")
    }
}
