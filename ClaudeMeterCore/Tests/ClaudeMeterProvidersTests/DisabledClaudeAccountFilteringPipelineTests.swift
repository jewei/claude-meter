import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("Disabled Claude account filtering")
struct DisabledClaudeAccountFilteringPipelineTests {
    @Test("Cached fallback filters a disabled account without the statusline tier")
    func cachedFallbackFiltersDisabledAccount() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-disabled-cache-\(UUID().uuidString)")
        let store = SnapshotStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaultTime = Date(timeIntervalSince1970: 1_800_000_000)
        let workTime = defaultTime.addingTimeInterval(60)
        let defaultLimits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 10),
            currentWeekAllModels: LimitWindow(percentUsed: 20))
        let workLimits = LimitInfo(
            currentSession: LimitWindow(percentUsed: 90),
            currentWeekAllModels: LimitWindow(percentUsed: 80))
        let defaultAccount = AccountUsage(
            id: "claude",
            label: "default",
            account: AccountInfo(plan: "Pro"),
            session: SessionInfo(activeModel: "default-model"),
            limits: defaultLimits,
            lastSuccessfulPollAt: defaultTime,
            severity: .normal,
            isActive: false)
        let disabledAccount = AccountUsage(
            id: "claude-work",
            label: "work",
            account: AccountInfo(plan: "Max"),
            session: SessionInfo(activeModel: "work-model"),
            limits: workLimits,
            lastSuccessfulPollAt: workTime,
            severity: .critical,
            isActive: true)
        var cached = ClaudeUsageSnapshot(
            parserVersion: "test-1.0",
            createdAt: defaultTime,
            lastSuccessfulPollAt: workTime,
            source: SourceInfo(cliPath: "/test", command: "test"),
            account: disabledAccount.account,
            session: disabledAccount.session,
            limits: disabledAccount.limits,
            state: SnapshotState(status: .ok, severity: .critical),
            accounts: [disabledAccount, defaultAccount])
        cached.state.isStale = false
        try store.writeLatest(cached)

        let pipeline = DisabledClaudeAccountFilteringPipeline(
            upstream: CachedSnapshotPipeline(store: store),
            disabledAccountKeys: ["claude-work"])
        let result = try await pipeline.poll(now: defaultTime, kind: .background)
        let snapshot = try #require(result.snapshot)

        #expect(snapshot.accounts == nil)
        #expect(snapshot.account == defaultAccount.account)
        #expect(snapshot.session == defaultAccount.session)
        #expect(snapshot.limits == defaultLimits)
        #expect(snapshot.lastSuccessfulPollAt == defaultTime)
        #expect(snapshot.state.severity == .normal)
        #expect(snapshot.state.isStale)
        #expect(result.sourceAttempts.last?.source == .cache)
        #expect(result.sourceAttempts.last?.outcome == .selected)
    }
}
