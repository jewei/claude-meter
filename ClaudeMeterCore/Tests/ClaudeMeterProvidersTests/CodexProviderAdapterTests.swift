import ClaudeMeterCore
import Foundation
import Testing

@testable import ClaudeMeterProviders

private final class CountingCodexDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    var archiveWrites: Int { lock.withLock { writes } }
    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "codexLastGoodReadings.v1" { lock.withLock { writes += 1 } }
        super.set(value, forKey: defaultName)
    }
}

/// Only the first archive write blocks. Queue-order and executor checks do not
/// depend on how long it takes the test to resume on MainActor.
private final class GatedCodexDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var wroteOnMain = false
    private var readOnMain = false
    private var saved: [Data] = []
    var mainActorIO: Bool { lock.withLock { wroteOnMain || readOnMain } }
    var archives: [Data] { lock.withLock { saved } }

    override func data(forKey defaultName: String) -> Data? {
        if defaultName == "codexLastGoodReadings.v1" {
            lock.withLock { readOnMain = readOnMain || Thread.isMainThread }
        }
        return super.data(forKey: defaultName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard defaultName == "codexLastGoodReadings.v1", let data = value as? Data else {
            super.set(value, forKey: defaultName)
            return
        }
        let (first, waiting) = lock.withLock {
            wroteOnMain = wroteOnMain || Thread.isMainThread
            let first = !started
            started = true
            let waiting = waiter
            waiter = nil
            return (first, waiting)
        }
        waiting?.resume()
        // A regression reports an assertion instead of blocking the test's main thread.
        if first && !Thread.isMainThread { release.wait() }
        super.set(data, forKey: defaultName)
        lock.withLock { saved.append(data) }
    }

    @MainActor func waitForFirstWrite() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if started { return true }
                waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func releaseFirstWrite() { release.signal() }
}

private final class IdentityFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CodexCredentialIdentity
    init(owner: String? = "owner-a", fingerprint: String? = "initial") {
        value = .init(ownerID: owner, sourceFingerprint: fingerprint)
    }
    func read() -> CodexCredentialIdentity { lock.withLock { value } }
    func replace(owner: String?, fingerprint: String?) {
        lock.withLock { value = .init(ownerID: owner, sourceFingerprint: fingerprint) }
    }
}

private final class BlockedIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    func read() -> CodexCredentialIdentity {
        lock.withLock { calls += 1 }
        release.wait()
        return .unavailable
    }
    func finish() { release.signal() }
}

private actor CodexFetchFixture {
    var failures: Set<String> = []
    var calls: [String] = []
    func fail(_ ids: Set<String>) { failures = ids }
    func fetch(_ account: CodexAccount, now: Date) throws -> CodexUsage {
        calls.append(account.id)
        if failures.contains(account.id) { throw URLError(.notConnectedToInternet) }
        return testUsage(now)
    }
}

private actor SuspendedHomeFetch {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls = 0
    func suspend() async {
        calls += 1
        let ready = waiters.filter { $0.0 <= calls }
        waiters.removeAll { $0.0 <= calls }
        for (_, waiter) in ready { waiter.resume() }
        await withCheckedContinuation { pending.append($0) }
    }
    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release() {
        let saved = pending
        pending.removeAll()
        for continuation in saved { continuation.resume() }
    }
}

private func testUsage(_ now: Date) -> CodexUsage {
    CodexUsage(
        primaryWindow: CodexLimitWindow(
            kind: .primary, usedPercent: 25,
            resetAt: now.addingTimeInterval(3600), durationSeconds: 18_000, rawLabel: nil),
        secondaryWindow: nil, usageCredits: CodexCredits(remaining: 12),
        rateLimitResets: CodexRateLimitResets(
            availableCount: 3,
            credits: [
                CodexRateLimitResetCredit(
                    title: "Full reset", expiresAt: now.addingTimeInterval(86_400))
            ]),
        accountEmail: "person@example.com", plan: "plus", authMode: .chatGPT,
        source: .appServer, updatedAt: now)
}

@Suite("Codex normalized provider", .timeLimit(.minutes(1)))
@MainActor
struct CodexProviderAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let accounts = ["personal", "work"].map { (name: String) in
        CodexAccount(
            home: URL(fileURLWithPath: "/test/\(name)"), isImplicit: false, customName: name)
    }

    private func isolated(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let suite = "CodexProvider-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    private func provider(
        _ defaults: UserDefaults, fetcher: CodexFetchFixture,
        identity: IdentityFixture = IdentityFixture()
    ) -> CodexProviderAdapter {
        let accounts = accounts
        return CodexProviderAdapter(
            configuration: { .init(accounts: accounts) },
            defaults: defaults, identityLoader: { _ in identity.read() },
            fetchAccount: { try await fetcher.fetch($0, now: $1) })
    }

    private func fetch(_ provider: CodexProviderAdapter, previous: ProviderSnapshot? = nil)
        async throws -> ProviderSnapshot
    {
        let id = UUID()
        let reconciled = try await provider.validatePrevious(previous, now: now, refreshID: id)
        let result = try await provider.fetch(now: now, previous: reconciled, refreshID: id)
        provider.didAccept(result, refreshID: id)
        await provider.waitForPersistence()
        return result
    }

    @Test("Ordered homes retain independent fresh, stale and unavailable accounts")
    func partialResults() async throws {
        try await isolated { defaults in
            let fetcher = CodexFetchFixture()
            let provider = provider(defaults, fetcher: fetcher)
            let first = try await fetch(provider)
            #expect(first.accounts.map(\.id) == accounts.map(\.id))
            #expect(first.accounts.allSatisfy { !$0.isStale && $0.lastError == nil })
            #expect(first.accounts[0].balances.first { $0.id == "usage-resets" }?.value == 3)
            await fetcher.fail([accounts[1].id])
            let mixed = try await fetch(provider, previous: first)
            #expect(!mixed.accounts[0].isStale)
            #expect(mixed.accounts[1].isStale)
            #expect(mixed.accounts[1].observedAt == first.accounts[1].observedAt)
            #expect(mixed.accounts[1].lastError != nil)
            #expect(mixed.accounts[1].lastAttemptAt != nil)
            await fetcher.fail(Set(accounts.map(\.id)))
            let stale = try await fetch(provider, previous: mixed)
            #expect(stale.accounts.allSatisfy { $0.isStale })
            #expect(stale.accounts.map(\.observedAt) == mixed.accounts.map(\.observedAt))
            await fetcher.fail([])
            let recovered = try await fetch(provider, previous: stale)
            #expect(recovered.accounts.allSatisfy { !$0.isStale && $0.lastError == nil })
        }
        try await isolated { defaults in
            let fetcher = CodexFetchFixture()
            await fetcher.fail([accounts[1].id])
            let mixed = try await fetch(provider(defaults, fetcher: fetcher))
            #expect(mixed.accounts.count == 2)
            #expect(mixed.accounts[0].observedAt != nil)
            #expect(mixed.accounts[1].observedAt == nil)
            #expect(mixed.accounts[1].windows.isEmpty)
            #expect(mixed.accounts[1].lastError != nil)
            await fetcher.fail(Set(accounts.map(\.id)))
            let allFailed = try await fetch(provider(defaults, fetcher: fetcher))
            // The saved healthy account can still be restored while offline.
            #expect(allFailed.accounts[0].isStale)
            #expect(allFailed.accounts[1].observedAt == nil)
        }
    }

    @Test("All first attempts fail without invented zero usage")
    func allFailed() async throws {
        try await isolated { defaults in
            let fetcher = CodexFetchFixture()
            await fetcher.fail(Set(accounts.map(\.id)))
            let result = try await fetch(provider(defaults, fetcher: fetcher))
            #expect(result.accounts.map(\.id) == accounts.map(\.id))
            #expect(result.accounts.allSatisfy { $0.observedAt == nil && $0.lastError != nil })
            #expect(result.accounts.allSatisfy { $0.windows.isEmpty })
        }
    }

    @Test("Same owner retains data through token rotation; changed owner cannot inherit it")
    func ownership() async throws {
        try await isolated { defaults in
            let fetcher = CodexFetchFixture()
            let identity = IdentityFixture()
            let provider = provider(defaults, fetcher: fetcher, identity: identity)
            let first = try await fetch(provider)
            identity.replace(owner: "owner-a", fingerprint: "rotated-secret")
            await fetcher.fail(Set(accounts.map(\.id)))
            let retained = try await fetch(provider, previous: first)
            #expect(retained.accounts.allSatisfy { $0.isStale })
            #expect(retained.accounts.map(\.observedAt) == first.accounts.map(\.observedAt))
            identity.replace(owner: "owner-b", fingerprint: "new-login")
            let id = UUID()
            let validated = try await provider.validatePrevious(retained, now: now, refreshID: id)
            let changed = try await provider.fetch(now: now, previous: validated, refreshID: id)
            #expect(validated?.accounts.isEmpty == true)
            #expect(changed.accounts.allSatisfy { $0.observedAt == nil })
        }
    }

    @Test(
        "Unknown owners require an unchanged fingerprint and never retain or persist usage",
        arguments: [true, false])
    func unknownOwner(_ unchanged: Bool) async throws {
        try await isolated { defaults in
            let identity = IdentityFixture(owner: nil)
            let accounts = accounts
            let provider = CodexProviderAdapter(
                configuration: { .init(accounts: accounts) }, defaults: defaults,
                identityLoader: { _ in identity.read() },
                fetchAccount: { _, now in
                    if !unchanged { identity.replace(owner: nil, fingerprint: "changed") }
                    return testUsage(now)
                })
            let result = try await fetch(provider)
            #expect(result.accounts.allSatisfy { ($0.observedAt != nil) == unchanged })
            #expect(await CodexReadingStore(defaults: defaults).entries().isEmpty)
            let offline = self.provider(defaults, fetcher: CodexFetchFixture(), identity: identity)
            let valid = try await offline.validatePrevious(result, now: now, refreshID: UUID())
            #expect(valid?.accounts.isEmpty == true)
        }
    }

    @Test(
        "A sign-in change during success or failure rejects publication", arguments: [false, true])
    func changedDuringFetch(_ fails: Bool) async throws {
        try await isolated { defaults in
            let identity = IdentityFixture()
            let gate = SuspendedHomeFetch()
            let accounts = accounts
            let provider = CodexProviderAdapter(
                configuration: { .init(accounts: accounts) }, defaults: defaults,
                identityLoader: { _ in identity.read() },
                fetchAccount: { _, now in
                    await gate.suspend()
                    if fails { throw URLError(.notConnectedToInternet) }
                    return testUsage(now)
                })
            let task = Task { try await fetch(provider) }
            await gate.waitForCalls(2)
            identity.replace(owner: "owner-b", fingerprint: "different")
            await gate.release()
            let result = try await task.value
            #expect(result.accounts.allSatisfy { $0.observedAt == nil })
            #expect(
                result.accounts.allSatisfy { $0.lastError?.contains("sign-in changed") == true })
        }
    }

    @Test("Archive format, ownership validation, reset details and privacy survive relaunch")
    func persistence() async throws {
        try await isolated { defaults in
            let fetcher = CodexFetchFixture()
            let initial = try await fetch(provider(defaults, fetcher: fetcher))
            let key = "codexLastGoodReadings.v1"
            let data = try #require(defaults.data(forKey: key))
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("person@example.com"))
            #expect(!text.contains("sourceFingerprint"))
            #expect(!text.contains("initial"))
            await fetcher.fail(Set(accounts.map(\.id)))
            let restored = try await fetch(provider(defaults, fetcher: fetcher))
            #expect(restored.accounts.map(\.observedAt) == initial.accounts.map(\.observedAt))
            #expect(restored.accounts[0].balances == initial.accounts[0].balances)
            let otherOwner = try await fetch(
                provider(
                    defaults, fetcher: fetcher,
                    identity: IdentityFixture(owner: "owner-b")))
            #expect(otherOwner.accounts.allSatisfy { $0.observedAt == nil })
            // The shipped v2 JSON remains accepted; v1 cannot prove ownership.
            defaults.set(data, forKey: key)
            #expect(await CodexReadingStore(defaults: defaults).entries().count == 2)
            var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            legacy["schemaVersion"] = 1
            defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: key)
            #expect(await CodexReadingStore(defaults: defaults).entries().isEmpty)
        }
    }

    @Test("Current configuration controls each refresh, including order and names")
    func configurationChanges() async throws {
        try await isolated { defaults in
            let fetcher = CodexFetchFixture()
            var configuration = CodexConfiguration(accounts: accounts)
            let provider = CodexProviderAdapter(
                configuration: { configuration }, defaults: defaults,
                identityLoader: { _ in .init(ownerID: "owner", sourceFingerprint: "stable") },
                fetchAccount: { try await fetcher.fetch($0, now: $1) })
            let first = try await fetch(provider)
            let renamed = CodexAccount(
                home: accounts[1].home, isImplicit: false, customName: "Renamed")
            configuration = .init(accounts: [renamed])
            let second = try await fetch(provider, previous: first)
            #expect(second.accounts.map(\.id) == [renamed.id])
            #expect(second.accounts[0].label == "Renamed")
            #expect(await fetcher.calls.last == renamed.id)
            #expect(await CodexReadingStore(defaults: defaults).entries().count == 1)
        }
    }

    @Test("A blocked identity read cannot consume new workers on each refresh")
    func blockedIdentityIsIsolated() async throws {
        try await isolated { defaults in
            let blocked = BlockedIdentity()
            defer { blocked.finish() }
            let accounts = accounts
            let provider = CodexProviderAdapter(
                configuration: { .init(accounts: accounts) },
                defaults: defaults, timeoutSeconds: 0.4, perAccountTimeoutSeconds: 0.1,
                identityLoader: { account in
                    if account.id == accounts[0].id { return blocked.read() }
                    return .init(ownerID: "healthy", sourceFingerprint: "stable")
                }, fetchAccount: { _, now in testUsage(now) })
            var previous: ProviderSnapshot?
            for _ in 0..<4 {
                let result = try await fetch(provider, previous: previous)
                #expect(result.accounts[0].observedAt == nil)
                #expect(result.accounts[1].windows.first?.usedPercent == 25)
                #expect(blocked.callCount == 1)
                previous = result
            }
        }
    }

    @Test("A changed owner is cleared before a suspended fetch ends")
    func invalidationBeforeFetch() async throws {
        try await isolated { defaults in
            let fetcher = CodexFetchFixture()
            let first = try await fetch(provider(defaults, fetcher: fetcher))
            let gate = SuspendedHomeFetch()
            let accounts = accounts
            let changed = CodexProviderAdapter(
                configuration: { .init(accounts: accounts) }, defaults: defaults,
                identityLoader: { _ in .init(ownerID: "new-owner", sourceFingerprint: "new") },
                fetchAccount: { _, _ in
                    await gate.suspend()
                    throw URLError(.notConnectedToInternet)
                })
            let id = UUID()
            let validated = try await changed.validatePrevious(first, now: now, refreshID: id)
            let task = Task {
                try await changed.fetch(now: now, previous: validated, refreshID: id)
            }
            await gate.waitForCalls(2)
            #expect(validated?.accounts.isEmpty == true)
            await gate.release()
            let result = try await task.value
            #expect(result.accounts.allSatisfy { $0.observedAt == nil })
        }
    }

    @Test("Shipped v2 archives decode; malformed reset dates remain unknown")
    func legacyArchiveCompatibility() async throws {
        try await isolated { defaults in
            // JSON fields match the pre-store archive. New account lifecycle fields
            // are not required, because the persisted format has not changed.
            let data = Data(
                #"{"schemaVersion":2,"entries":{"/test/personal":{"ownerID":"owner-a","lastSuccessfulAt":800000000,"usage":{"primaryWindow":{"kind":"primary","usedPercent":25,"resetAt":1e308,"durationSeconds":18000},"plan":"plus","source":"appServer","authMode":"chatGPT","updatedAt":800000000}}}}"#
                    .utf8)
            defaults.set(data, forKey: "codexLastGoodReadings.v1")
            let entries = await CodexReadingStore(defaults: defaults).entries()
            let entry = try #require(entries[accounts[0].id])
            #expect(entry.usage.primaryWindow?.resetAt == nil)
            let fetcher = CodexFetchFixture()
            await fetcher.fail(Set(accounts.map(\.id)))
            let result = try await fetch(provider(defaults, fetcher: fetcher))
            #expect(result.accounts[0].isStale)
            #expect(result.accounts[0].windows.first?.usedPercent == 25)
            #expect(result.accounts[0].windows.first?.resetAt == nil)
            #expect(
                result.accounts[0].observedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
        }
    }

    @Test(
        "Accepted writes stay off-main and ordered while a newer refresh proceeds",
        arguments: [false, true])
    func orderedPersistence(transientFailure: Bool) async throws {
        let suite = "CodexOrderedWrites-\(UUID().uuidString)"
        let defaults = GatedCodexDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { defaults.releaseFirstWrite() }
        let fetcher = CodexFetchFixture()
        let provider = provider(defaults, fetcher: fetcher)
        let firstID = UUID()
        let firstPrevious = try await provider.validatePrevious(nil, now: now, refreshID: firstID)
        let first = try await provider.fetch(now: now, previous: firstPrevious, refreshID: firstID)
        provider.didAccept(first, refreshID: firstID)
        await defaults.waitForFirstWrite()
        let firstWait = Task { await provider.waitForPersistence() }
        #expect(defaults.archives.isEmpty)
        #expect(provider.sourceDiagnostics.count == accounts.count)

        // A newer refresh must see A's accepted ownership/archive before A reaches disk.
        let secondID = UUID()
        let next = now.addingTimeInterval(60)
        let reconciled = try await provider.validatePrevious(first, now: next, refreshID: secondID)
        #expect(reconciled?.accounts == first.accounts)
        if transientFailure { await fetcher.fail(Set(accounts.map(\.id))) }
        let second = try await provider.fetch(now: next, previous: reconciled, refreshID: secondID)
        provider.didAccept(second, refreshID: secondID)
        provider.didAccept(second, refreshID: secondID)
        provider.didAccept(first, refreshID: firstID)
        #expect(defaults.archives.isEmpty)
        firstWait.cancel()  // Cancellation cannot revoke an already accepted write.
        defaults.releaseFirstWrite()
        await provider.waitForPersistence()
        await firstWait.value

        #expect(!defaults.mainActorIO)
        #expect(defaults.archives.count == 2)
        let archive = await CodexReadingStore(defaults: defaults).entries()
        #expect(archive.count == accounts.count)
        let expected = transientFailure ? now : next
        #expect(archive.values.allSatisfy { $0.usage.updatedAt == expected })
        #expect(archive[accounts[0].id]?.lastSuccessfulAt == second.accounts[0].observedAt)
        #expect(second.accounts.allSatisfy { $0.isStale == transientFailure })
        #expect(!defaults.mainActorIO)
    }

    @Test("Only the current accepted result saves, and it saves exactly once")
    func explicitAcceptance() async throws {
        let suite = "CodexAccept-\(UUID().uuidString)"
        let defaults = CountingCodexDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = provider(defaults, fetcher: CodexFetchFixture())
        let oldID = UUID()
        let oldPrevious = try await provider.validatePrevious(nil, now: now, refreshID: oldID)
        let old = try await provider.fetch(now: now, previous: oldPrevious, refreshID: oldID)
        #expect(defaults.archiveWrites == 0)
        let newID = UUID()
        let newPrevious = try await provider.validatePrevious(nil, now: now, refreshID: newID)
        let current = try await provider.fetch(now: now, previous: newPrevious, refreshID: newID)
        provider.didAccept(old, refreshID: oldID)
        #expect(defaults.archiveWrites == 0)
        provider.didAccept(current, refreshID: newID)
        await provider.waitForPersistence()
        #expect(defaults.archiveWrites == 1)
        provider.didAccept(current, refreshID: newID)
        await provider.waitForPersistence()
        provider.didAccept(old, refreshID: oldID)
        #expect(defaults.archiveWrites == 1)
        #expect(await CodexReadingStore(defaults: defaults).entries().count == accounts.count)
    }

    @Test("API-key recovery cannot retain a subscription reading")
    func apiKeyRecoveryUnavailable() async throws {
        try await isolated { defaults in
            let accounts = accounts
            let date = now
            let provider = CodexProviderAdapter(
                configuration: { .init(accounts: accounts) }, defaults: defaults,
                identityLoader: { _ in .init(ownerID: "owner", sourceFingerprint: "stable") },
                fetchAccount: { _, now in
                    if now > date { throw CodexOAuthCredentialsError.apiKeyOnly }
                    return testUsage(now)
                })
            let first = UUID()
            let valid = try await provider.validatePrevious(nil, now: date, refreshID: first)
            let snapshot = try await provider.fetch(now: date, previous: valid, refreshID: first)
            provider.didAccept(snapshot, refreshID: first)
            await provider.waitForPersistence()
            let second = UUID()
            let next = date.addingTimeInterval(300)
            let previous = try await provider.validatePrevious(
                snapshot, now: next, refreshID: second)
            let unavailable = try await provider.fetch(
                now: next, previous: previous, refreshID: second)
            #expect(unavailable.accounts.allSatisfy { $0.observedAt == nil && $0.windows.isEmpty })
            #expect(unavailable.accounts.allSatisfy { $0.lastError?.contains("API-key") == true })
        }
    }

    @Test("A late old fetch cannot replace the new pending save")
    func overlappingStages() async throws {
        try await isolated { defaults in
            let accounts = accounts
            let gate = SuspendedHomeFetch()
            let provider = CodexProviderAdapter(
                configuration: { .init(accounts: accounts) }, defaults: defaults,
                identityLoader: { _ in .init(ownerID: "owner", sourceFingerprint: "stable") },
                fetchAccount: { _, date in
                    if date == now { await gate.suspend() }
                    return testUsage(date)
                })
            let oldID = UUID()
            let oldPrevious = try await provider.validatePrevious(nil, now: now, refreshID: oldID)
            let old = Task {
                try await provider.fetch(now: now, previous: oldPrevious, refreshID: oldID)
            }
            await gate.waitForCalls(accounts.count)
            let newID = UUID()
            let newDate = now.addingTimeInterval(1)
            let newPrevious = try await provider.validatePrevious(
                nil, now: newDate, refreshID: newID)
            let current = try await provider.fetch(
                now: newDate, previous: newPrevious, refreshID: newID)
            await gate.release()
            do {
                _ = try await old.value
                Issue.record("An obsolete fetch must be rejected")
            } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
            #expect(defaults.data(forKey: "codexLastGoodReadings.v1") == nil)
            provider.didAccept(current, refreshID: newID)
            await provider.waitForPersistence()
            #expect(await CodexReadingStore(defaults: defaults).entries().count == accounts.count)
        }
    }

    @Test("One deadline bounds batches and abandoned fetch work")
    func deadlines() async throws {
        try await isolated { defaults in
            let accounts = (0..<4).map {
                CodexAccount(
                    home: URL(fileURLWithPath: "/test/\($0)"), isImplicit: false, customName: nil)
            }
            let gate = SuspendedHomeFetch()
            let provider = CodexProviderAdapter(
                configuration: { .init(accounts: accounts) }, defaults: defaults,
                timeoutSeconds: 0.2, perAccountTimeoutSeconds: 1,
                identityLoader: { _ in .init(ownerID: "owner", sourceFingerprint: "stable") },
                fetchAccount: { _, now in
                    await gate.suspend()
                    return testUsage(now)
                })
            let start = Date()
            let task = Task { try await fetch(provider) }
            await gate.waitForCalls(3)
            let result = try await task.value
            #expect(Date().timeIntervalSince(start) < 1)
            #expect(await gate.calls == 3)
            #expect(result.accounts.count == 4)
            #expect(result.accounts.allSatisfy { $0.observedAt == nil && $0.lastError != nil })
            _ = try await fetch(provider)
            #expect(await gate.calls == 6)
            _ = try await fetch(provider)
            #expect(await gate.calls == 6)  // The two abandoned batches fill the fixed budget.
            await gate.release()
        }
    }
}
