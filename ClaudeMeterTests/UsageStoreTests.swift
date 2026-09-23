import ClaudeMeterCore
import ClaudeMeterProviders
import Combine
import Foundation
import Testing

@testable import ClaudeMeter

private final class CommitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []
    var accepted: [UUID] { lock.withLock { ids } }
    func record(_ id: UUID) { lock.withLock { ids.append(id) } }
}

/// Suspends persistence without blocking a thread or depending on elapsed time.
private actor PersistenceGate {
    private var count = 0
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func suspend() async {
        count += 1
        let request = count
        await withCheckedContinuation { continuation in
            pending[request] = continuation
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func release() {
        let saved = pending
        pending.removeAll()
        for continuation in saved.values { continuation.resume() }
    }
}

/// Ignores cancellation so tests can deliver results after disable/supersession.
private actor ControlledUsageProvider: UsageProvider {
    nonisolated let id: ProviderID
    nonisolated let ownsDeadline: Bool
    private var count = 0
    private var refreshIDs: [Int: UUID] = [:]
    nonisolated let commits = CommitRecorder()
    private let persistence: PersistenceGate?
    private var previousValues: [Int: ProviderSnapshot] = [:]
    private var pending: [Int: CheckedContinuation<ProviderSnapshot, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(_ id: ProviderID, ownsDeadline: Bool = false, persistence: PersistenceGate? = nil) {
        self.id = id
        self.ownsDeadline = ownsDeadline
        self.persistence = persistence
    }

    func fetch(
        now: Date, previous: ProviderSnapshot?, refreshID: UUID
    ) async throws -> ProviderSnapshot {
        count += 1
        let request = count
        refreshIDs[request] = refreshID
        previousValues[request] = previous
        return try await withCheckedThrowingContinuation { continuation in
            pending[request] = continuation
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func succeed(_ request: Int, with snapshot: ProviderSnapshot) {
        pending.removeValue(forKey: request)!.resume(returning: snapshot)
    }

    @MainActor func didAccept(_ snapshot: ProviderSnapshot, refreshID: UUID) {
        commits.record(refreshID)
    }

    func waitForPersistence() async { await persistence?.suspend() }

    func refreshID(_ request: Int) -> UUID { refreshIDs[request]! }

    func previous(_ request: Int) -> ProviderSnapshot? { previousValues[request] }

    func fail(_ request: Int, with error: any Error = TestFailure.offline) {
        pending.removeValue(forKey: request)!.resume(throwing: error)
    }
}

/// Reconciliation deliberately ignores cancellation, like a blocked file read.
@MainActor
private final class ControlledReconciliationProvider: UsageProvider {
    let id: ProviderID = .codex
    let ownsDeadline = true
    let result: ProviderSnapshot
    private var count = 0
    private var pending: [Int: CheckedContinuation<ProviderSnapshot?, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var fetched: [UUID] = []
    private(set) var accepted: [UUID] = []

    init(result: ProviderSnapshot) { self.result = result }

    func validatePrevious(_ previous: ProviderSnapshot?, now: Date, refreshID: UUID)
        async throws -> ProviderSnapshot?
    {
        count += 1
        let request = count
        return await withCheckedContinuation { continuation in
            pending[request] = continuation
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForValidation(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func reconcile(_ request: Int, to snapshot: ProviderSnapshot?) {
        pending.removeValue(forKey: request)!.resume(returning: snapshot)
    }

    func fetch(now: Date, previous: ProviderSnapshot?, refreshID: UUID) async throws
        -> ProviderSnapshot
    {
        fetched.append(refreshID)
        return result
    }

    func didAccept(_ snapshot: ProviderSnapshot, refreshID: UUID) { accepted.append(refreshID) }
}

private final class StoreCodexOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var owner = "original"
    func change() { lock.withLock { owner = "replacement" } }
    func read() -> CodexCredentialIdentity {
        lock.withLock { .init(ownerID: owner, sourceFingerprint: owner) }
    }
}

private actor StoreCodexFetch {
    private var calls = 0
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func fetch(now: Date) async -> CodexUsage {
        calls += 1
        if calls > 1 {
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume()
                started = nil
            }
        }
        return CodexUsage(
            primaryWindow: CodexLimitWindow(
                kind: .primary, usedPercent: 25,
                resetAt: nil, durationSeconds: 18_000, rawLabel: nil),
            secondaryWindow: nil, usageCredits: nil, accountEmail: nil, plan: "plus",
            source: .appServer, updatedAt: now)
    }

    func waitForBlockedFetch() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}

private enum TestFailure: Error, LocalizedError {
    case offline
    var errorDescription: String? { "Offline" }
}

@Suite("UsageStore", .timeLimit(.minutes(1)))
@MainActor
struct UsageStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ id: ProviderID, used: Double? = 25, at date: Date? = nil)
        -> ProviderSnapshot
    {
        let date = date ?? now
        return ProviderSnapshot(
            provider: id,
            accounts: [
                ProviderAccountSnapshot(
                    id: "default", label: id.rawValue,
                    windows: [
                        UsageWindow(
                            id: "quota", title: "Quota", kind: .billing,
                            usedPercent: used, resetAt: date.addingTimeInterval(3600))
                    ],
                    observedAt: date)
            ], fetchedAt: date)
    }

    private func store(_ cursor: ControlledUsageProvider, _ grok: ControlledUsageProvider)
        -> UsageStore
    {
        let store = UsageStore(providers: [cursor, grok])
        store.setEnabled(.cursor, enabled: true)
        store.setEnabled(.grok, enabled: true)
        return store
    }

    @Test(
        "Success, stale last-good and recovery retain coherent timestamps",
        arguments: ProviderID.allCases)
    func lifecycle(_ id: ProviderID) async throws {
        let provider = ControlledUsageProvider(id)
        let store = UsageStore(providers: [provider])
        store.setEnabled(id, enabled: true)
        let initial = snapshot(id, used: nil)
        let first = Task { await store.refresh([id], now: now) }
        await provider.waitForRequests(1)
        #expect(store.refreshing == [id])
        await provider.succeed(1, with: initial)
        await first.value
        guard case .current(let value, let observedAt) = store.reading(for: id) else {
            Issue.record("Expected current reading")
            return
        }
        #expect(value == initial)
        #expect(value.accounts[0].windows[0].usedPercent == nil)
        #expect(!value.accounts[0].isStale)
        #expect(observedAt == now)
        #expect(store.refreshing.isEmpty)

        let second = Task { await store.refresh([id], now: now.addingTimeInterval(60)) }
        await provider.waitForRequests(2)
        await provider.fail(2)
        await second.value
        guard case .stale(let retained, let retainedAt, let error) = store.reading(for: id) else {
            Issue.record("Expected stale reading")
            return
        }
        #expect(retained == initial)
        #expect(retainedAt == now)
        #expect(error == "Offline")
        // Failure belongs to the outer reading. The source observation is unchanged.
        #expect(!retained.accounts[0].isStale)
        #expect(store.refreshing.isEmpty)

        let recovered = snapshot(id, used: 50, at: now.addingTimeInterval(120))
        let third = Task { await store.refresh([id], now: recovered.fetchedAt) }
        await provider.waitForRequests(3)
        #expect(store.reading(for: id)?.isStale == true)
        #expect(store.reading(for: id)?.error == "Offline")
        await provider.succeed(3, with: recovered)
        await third.value
        #expect(store.reading(for: id)?.value == recovered)
        #expect(store.reading(for: id)?.error == nil)
        #expect(store.reading(for: id)?.isStale == false)
        #expect(store.reading(for: id)?.lastPolledAt == recovered.fetchedAt)
    }

    @Test("Failure without a prior value stays failed", arguments: ProviderID.allCases)
    func firstFailure(_ id: ProviderID) async {
        let provider = ControlledUsageProvider(id)
        let store = UsageStore(providers: [provider])
        store.setEnabled(id, enabled: true)
        let task = Task { await store.refresh([id]) }
        await provider.waitForRequests(1)
        await provider.fail(1)
        await task.value
        guard case .failed(let error, let lastPolledAt, _) = store.reading(for: id) else {
            Issue.record("Expected failed reading")
            return
        }
        #expect(error == "Offline")
        #expect(lastPolledAt == nil)
        #expect(store.refreshing.isEmpty)
    }

    @Test(
        "Providers start concurrently and fail independently",
        arguments: [ProviderID.cursor, .grok])
    func concurrency(_ failing: ProviderID) async {
        let cursor = ControlledUsageProvider(.cursor)
        let grok = ControlledUsageProvider(.grok)
        let store = store(cursor, grok)
        let task = Task { await store.refresh([.cursor, .grok]) }
        // Both must enter fetch before either completes.
        await cursor.waitForRequests(1)
        await grok.waitForRequests(1)
        #expect(store.refreshing == [.cursor, .grok])
        let healthy: ProviderID = failing == .cursor ? .grok : .cursor
        await (failing == .cursor ? cursor : grok).fail(1)
        await (healthy == .cursor ? cursor : grok).succeed(1, with: snapshot(healthy))
        await task.value
        #expect(store.reading(for: failing)?.value == nil)
        #expect(store.reading(for: failing)?.error == "Offline")
        #expect(store.reading(for: healthy)?.value == snapshot(healthy))
        #expect(store.reading(for: healthy)?.error == nil)
        #expect(store.refreshing.isEmpty)
    }

    @Test("Old completion cannot replace a newer result or end its loading state")
    func supersession() async {
        let cursor = ControlledUsageProvider(.cursor)
        let store = store(cursor, ControlledUsageProvider(.grok))
        let old = Task { await store.refresh([.cursor]) }
        await cursor.waitForRequests(1)
        let newer = Task { await store.refresh([.cursor]) }
        await cursor.waitForRequests(2)
        await old.value
        #expect(store.refreshing == [.cursor])
        let latest = snapshot(.cursor, used: 70)
        await cursor.succeed(2, with: latest)
        await newer.value
        await cursor.succeed(1, with: snapshot(.cursor, used: 10))
        #expect(store.reading(for: .cursor)?.value == latest)
        #expect(store.refreshing.isEmpty)
    }

    @Test("Disable clears data and blocks late work across re-enable")
    func disable() async {
        let grok = ControlledUsageProvider(.grok)
        let store = store(ControlledUsageProvider(.cursor), grok)
        let first = Task { await store.refresh([.grok]) }
        await grok.waitForRequests(1)
        await grok.succeed(1, with: snapshot(.grok))
        await first.value
        let old = Task { await store.refresh([.grok]) }
        await grok.waitForRequests(2)
        store.setEnabled(.grok, enabled: false)
        #expect(store.reading(for: .grok) == nil)
        #expect(store.refreshing.isEmpty)
        await old.value
        await store.refresh([.grok])  // Disabled providers cannot start a request.
        store.setEnabled(.grok, enabled: true)
        let newer = Task { await store.refresh([.grok]) }
        await grok.waitForRequests(3)
        await grok.succeed(2, with: snapshot(.grok, used: 90))
        #expect(store.reading(for: .grok) == nil)
        #expect(store.refreshing == [.grok])
        await grok.succeed(3, with: snapshot(.grok, used: 40))
        await newer.value
        #expect(store.reading(for: .grok)?.value == snapshot(.grok, used: 40))
    }

    @Test("Caller cancellation preserves current data", arguments: ProviderID.allCases)
    func cancellation(_ id: ProviderID) async {
        let provider = ControlledUsageProvider(id)
        let store = UsageStore(providers: [provider])
        store.setEnabled(id, enabled: true)
        let initial = Task { await store.refresh([id]) }
        await provider.waitForRequests(1)
        await provider.succeed(1, with: snapshot(id))
        await initial.value
        let cancelled = Task { await store.refresh([id]) }
        await provider.waitForRequests(2)
        cancelled.cancel()
        await cancelled.value
        #expect(store.reading(for: id)?.value == snapshot(id))
        #expect(store.reading(for: id)?.error == nil)
        #expect(store.reading(for: id)?.isStale == false)
        #expect(store.refreshing.isEmpty)
        await provider.fail(2)
        #expect(store.reading(for: id)?.error == nil)
    }

    @Test("Cancelling an older batch cannot cancel a newer provider request")
    func cancellationIsolation() async {
        let cursor = ControlledUsageProvider(.cursor)
        let grok = ControlledUsageProvider(.grok)
        let store = store(cursor, grok)
        let old = Task { await store.refresh([.cursor, .grok]) }
        await cursor.waitForRequests(1)
        await grok.waitForRequests(1)
        let newer = Task { await store.refresh([.cursor]) }
        await cursor.waitForRequests(2)
        old.cancel()
        await old.value
        #expect(store.refreshing == [.cursor])
        #expect(store.reading(for: .grok) == nil)
        await cursor.succeed(2, with: snapshot(.cursor))
        await newer.value
        await cursor.fail(1)
        await grok.fail(1)
        #expect(store.reading(for: .cursor)?.value == snapshot(.cursor))
    }

    @Test("Neutral credential failure clears last-good data but retains its timestamp")
    func invalidatedCredentials() async {
        let cursor = ControlledUsageProvider(.cursor)
        let store = store(cursor, ControlledUsageProvider(.grok))
        let first = Task { await store.refresh([.cursor]) }
        await cursor.waitForRequests(1)
        await cursor.succeed(1, with: snapshot(.cursor))
        await first.value
        let second = Task { await store.refresh([.cursor]) }
        await cursor.waitForRequests(2)
        await cursor.fail(
            2, with: UsageProviderFailure(TestFailure.offline, retainsLastGood: false))
        await second.value
        #expect(store.reading(for: .cursor)?.value == nil)
        #expect(store.reading(for: .cursor)?.lastPolledAt == now)
        #expect(store.reading(for: .cursor)?.error == "Offline")
    }

    @Test("AppState observes store changes and forwards only normalized values")
    func appProjection() async {
        let cursor = ControlledUsageProvider(.cursor)
        let grok = ControlledUsageProvider(.grok)
        let store = store(cursor, grok)
        let app = AppState(
            usageStore: store, onboardingIsComplete: false)
        var notifications = 0
        let observation = app.objectWillChange.sink { notifications += 1 }
        let task = Task { await store.refresh([.cursor, .grok]) }
        await cursor.waitForRequests(1)
        await grok.waitForRequests(1)
        await cursor.succeed(1, with: snapshot(.cursor))
        await grok.succeed(1, with: snapshot(.grok))
        await task.value
        #expect(app.cursorSnapshot == store.reading(for: .cursor)?.value)
        #expect(app.grokSnapshot == store.reading(for: .grok)?.value)
        #expect(app.normalizedSnapshots[.cursor] == app.cursorSnapshot)
        #expect(app.cursorLastPolledAt == now)
        #expect(app.grokError == nil)
        #expect(notifications > 0)
        store.setEnabled(.cursor, enabled: false)
        store.setEnabled(.grok, enabled: false)
        #expect(app.cursorSnapshot == nil)
        #expect(app.grokSnapshot == nil)
        #expect(store.readings.isEmpty)
        observation.cancel()
    }

    @Test(
        "Accepted data publishes before persistence; newer work and cancellation do not revoke it")
    func publicationBeforePersistence() async {
        let gate = PersistenceGate()
        let provider = ControlledUsageProvider(.codex, ownsDeadline: true, persistence: gate)
        let store = UsageStore(providers: [provider])
        store.setEnabled(.codex, enabled: true)
        var completed = 0
        let first = Task {
            await store.refresh([.codex])
            completed += 1
        }
        await provider.waitForRequests(1)
        await provider.succeed(1, with: snapshot(.codex, used: 25))
        await gate.waitForRequests(1)
        // This MainActor task runs while the first refresh awaits persistence.
        await Task { @MainActor in
            #expect(store.reading(for: .codex)?.value == snapshot(.codex, used: 25))
            #expect(store.refreshing.isEmpty)
            #expect(completed == 0)
        }.value
        let second = Task {
            await store.refresh([.codex])
            completed += 1
        }
        await provider.waitForRequests(2)
        #expect(await provider.previous(2) == snapshot(.codex, used: 25))
        first.cancel()
        await provider.succeed(2, with: snapshot(.codex, used: 70))
        await gate.waitForRequests(2)
        #expect(store.reading(for: .codex)?.value == snapshot(.codex, used: 70))
        #expect(completed == 0)
        #expect(provider.commits.accepted.count == 2)
        store.setEnabled(.codex, enabled: false)
        await gate.release()
        await first.value
        await second.value
        #expect(completed == 2)
        #expect(store.reading(for: .codex) == nil)
        #expect(provider.commits.accepted.count == 2)
    }

    @Test(
        "Multi-account provider owns its deadline but only the store accepts a completed observation",
        arguments: [ProviderID.claude, .codex])
    func codexSupersessionAndDisable(_ id: ProviderID) async {
        let codex = ControlledUsageProvider(id, ownsDeadline: true)
        let store = UsageStore(providers: [codex], timeoutSeconds: 0)
        store.setEnabled(id, enabled: true)

        let old = Task { await store.refresh([id]) }
        await codex.waitForRequests(1)
        let newer = Task { await store.refresh([id]) }
        await codex.waitForRequests(2)
        await codex.succeed(2, with: snapshot(id, used: 70))
        await newer.value
        #expect(store.reading(for: id)?.value == snapshot(id, used: 70))
        await codex.succeed(1, with: snapshot(id, used: 10))
        await old.value
        #expect(store.reading(for: id)?.value == snapshot(id, used: 70))
        #expect(codex.commits.accepted == [await codex.refreshID(2)])
        let canceled = Task { await store.refresh([id]) }
        await codex.waitForRequests(3)
        #expect(await codex.previous(3) == snapshot(id, used: 70))
        canceled.cancel()
        await codex.succeed(3, with: snapshot(id, used: 80))
        await canceled.value
        #expect(store.reading(for: id)?.value == snapshot(id, used: 70))
        #expect(store.reading(for: id)?.error == nil)
        let disabled = Task { await store.refresh([id]) }
        await codex.waitForRequests(4)
        store.setEnabled(id, enabled: false)
        #expect(store.reading(for: id) == nil)
        await codex.succeed(4, with: snapshot(id, used: 90))
        await disabled.value
        #expect(store.reading(for: id) == nil)
        #expect(store.refreshing.isEmpty)
        #expect(codex.commits.accepted == [await codex.refreshID(2)])
        store.setEnabled(id, enabled: true)
        let enabled = Task { await store.refresh([id]) }
        await codex.waitForRequests(5)
        await codex.succeed(5, with: snapshot(id, used: 40))
        await enabled.value
        #expect(store.reading(for: id)?.value == snapshot(id, used: 40))
    }

    @Test(
        "All provider failures remain independent",
        arguments: ProviderID.allCases)
    func codexFailureIsolation(_ failing: ProviderID) async {
        let providers = ProviderID.allCases.map { ControlledUsageProvider($0) }
        let store = UsageStore(providers: providers)
        for provider in providers { store.setEnabled(provider.id, enabled: true) }
        let task = Task { await store.refresh(Set(ProviderID.allCases)) }
        for provider in providers { await provider.waitForRequests(1) }
        #expect(store.refreshing == Set(ProviderID.allCases))
        for provider in providers {
            if provider.id == failing {
                await provider.fail(1)
            } else {
                await provider.succeed(1, with: snapshot(provider.id))
            }
        }
        await task.value
        for provider in providers {
            #expect((store.reading(for: provider.id)?.error != nil) == (provider.id == failing))
        }
    }

    @Test(
        "Partial Multi-account provider failures stay current; wholly unavailable accounts stay visible as failed",
        arguments: [ProviderID.claude, .codex])
    func codexPartialFailureState(_ id: ProviderID) async {
        let codex = ControlledUsageProvider(id)
        let store = UsageStore(providers: [codex])
        store.setEnabled(id, enabled: true)
        let fresh = snapshot(id).accounts[0]
        let stale = ProviderAccountSnapshot(
            id: "stale", label: "Stale", windows: fresh.windows,
            observedAt: now, isStale: true, lastError: "Offline")
        let failed = ProviderAccountSnapshot(
            id: "work", label: "Work", windows: [],
            observedAt: nil, lastError: "Sign in required")
        for (index, accounts) in [[fresh, stale], [fresh, failed], [stale, failed], [failed]]
            .enumerated()
        {
            let result = ProviderSnapshot(provider: id, accounts: accounts, fetchedAt: now)
            let task = Task { await store.refresh([id]) }
            await codex.waitForRequests(index + 1)
            await codex.succeed(index + 1, with: result)
            await task.value
            #expect(store.reading(for: id)?.value == result)
            if index == 3 {
                guard case .failed(_, let date, let unavailable) = store.reading(for: id) else {
                    Issue.record("Expected failed provider with account errors")
                    return
                }
                #expect(date == nil)
                #expect(unavailable?.accounts[0].lastError == "Sign in required")
            } else {
                guard case .current = store.reading(for: id) else {
                    Issue.record("A usable account must keep the provider current")
                    return
                }
            }
        }
    }

    @Test("Obsolete reconciliation cannot publish, fetch or commit")
    func obsoleteReconciliation() async {
        let expected = snapshot(.codex, used: 70)
        let provider = ControlledReconciliationProvider(result: expected)
        let store = UsageStore(providers: [provider])
        store.setEnabled(.codex, enabled: true)
        let old = Task { await store.refresh([.codex]) }
        await provider.waitForValidation(1)
        let newer = Task { await store.refresh([.codex]) }
        await provider.waitForValidation(2)
        provider.reconcile(2, to: snapshot(.codex, used: 50))
        await newer.value
        provider.reconcile(1, to: snapshot(.codex, used: 10))
        await old.value
        #expect(store.reading(for: .codex)?.value == expected)
        #expect(provider.fetched.count == 1)
        #expect(provider.accepted == provider.fetched)
        #expect(store.refreshing.isEmpty)
    }

    @Test("Disable and cancellation reject pending reconciliation", arguments: [false, true])
    func cancelledReconciliation(disable: Bool) async {
        let previous = snapshot(.codex, used: 70)
        let provider = ControlledReconciliationProvider(result: previous)
        let store = UsageStore(providers: [provider])
        store.setEnabled(.codex, enabled: true)
        let first = Task { await store.refresh([.codex]) }
        await provider.waitForValidation(1)
        provider.reconcile(1, to: nil)
        await first.value
        let interrupted = Task { await store.refresh([.codex]) }
        await provider.waitForValidation(2)
        if disable { store.setEnabled(.codex, enabled: false) } else { interrupted.cancel() }
        provider.reconcile(2, to: snapshot(.codex, used: 5))
        await interrupted.value
        #expect(store.reading(for: .codex)?.value == (disable ? nil : previous))
        #expect(store.reading(for: .codex)?.error == nil)
        #expect(provider.fetched.count == 1)
        #expect(provider.accepted.count == 1)
        #expect(store.refreshing.isEmpty)
    }

    @Test("The store removes a previous Codex owner before fetching, and disable prevents a save")
    func codexOwnershipStage() async throws {
        let suite = "CodexStoreStages-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = StoreCodexOwner()
        let fetcher = StoreCodexFetch()
        let provider = CodexProviderAdapter(
            configuration: {
                .init(
                    accounts: [
                        CodexAccount(
                            home: URL(fileURLWithPath: "/test/home"),
                            isImplicit: true, customName: nil)
                    ])
            }, defaults: defaults,
            identityLoader: { _ in owner.read() },
            fetchAccount: { _, now in await fetcher.fetch(now: now) })
        let store = UsageStore(providers: [provider])
        store.setEnabled(.codex, enabled: true)
        await store.refresh([.codex], now: now)
        #expect(store.reading(for: .codex)?.value?.accounts.first?.windows.first?.usedPercent == 25)
        let saved = try #require(defaults.data(forKey: "codexLastGoodReadings.v1"))
        owner.change()
        let refreshing = Task { await store.refresh([.codex], now: now) }
        await fetcher.waitForBlockedFetch()
        #expect(store.reading(for: .codex)?.value?.accounts.isEmpty == true)
        #expect(store.refreshing.contains(.codex))
        store.setEnabled(.codex, enabled: false)
        await refreshing.value
        await fetcher.release()
        #expect(store.reading(for: .codex) == nil)
        #expect(defaults.data(forKey: "codexLastGoodReadings.v1") == saved)
    }

    @Test("Normalized card copy retains period spend and on-demand cap")
    func presentation() {
        let reset = now.addingTimeInterval(7200)
        let cursor = ProviderAccountSnapshot(
            id: "default", label: "Cursor", plan: "Pro+",
            windows: [
                UsageWindow(
                    id: "billing", title: "Billing period", kind: .billing, usedPercent: 20,
                    resetAt: reset)
            ],
            balances: [
                BalanceItem(
                    id: "billing", title: "Period spend", value: Decimal(string: "120.25"),
                    limit: 100, unit: "USD")
            ], observedAt: now)
        #expect(PopoverView.cursorSubtitle(cursor, asOf: now) == "$120.25 spent · Resets in 2h")
        let grok = ProviderAccountSnapshot(
            id: "default", label: "Grok",
            windows: [
                UsageWindow(
                    id: "credits", title: "Weekly", kind: .billing, usedPercent: 40, resetAt: reset)
            ],
            balances: [
                BalanceItem(
                    id: "on-demand", title: "On-demand", value: Decimal(string: "12.34"), limit: 50,
                    unit: "USD"),
                BalanceItem(id: "prepaid", title: "Prepaid balance", value: 20, unit: "USD"),
            ], observedAt: now)
        #expect(
            PopoverView.grokSubtitle(grok, asOf: now)
                == "Weekly · On-demand $12.34 of $50.00 · Resets in 2h")
        #expect(grok.balances.last?.value == 20)
        let unknown = ProviderAccountSnapshot(
            id: "default", label: "Cursor", windows: [], observedAt: now)
        #expect(PopoverView.cursorSubtitle(unknown, asOf: now) == nil)
    }
}
