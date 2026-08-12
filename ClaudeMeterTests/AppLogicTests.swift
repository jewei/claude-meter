import ClaudeMeterCore
import ClaudeMeterProviders
import Foundation
import Testing

@testable import ClaudeMeter

@Suite("App logic")
struct AppLogicTests {
    private actor SuspendedStatusFetcher {
        private var continuation: CheckedContinuation<ServiceStatus?, Never>?
        private var completedResult: ServiceStatus??
        private(set) var callCount = 0

        func fetch() async -> ServiceStatus? {
            callCount += 1
            if let completedResult { return completedResult }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish(with status: ServiceStatus?) {
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: status)
            } else {
                completedResult = .some(status)
            }
        }
    }

    private struct UnusedPipeline: ClaudeMeterPipeline {
        func poll(now _: Date, kind _: RefreshKind) async throws -> ParseResult {
            ParseResult(snapshot: nil, warnings: [], errors: [], rawHash: "")
        }
    }

    @Test("Friendly account labels normalize separators")
    func friendlyAccountLabels() {
        #expect("it-oneone_build".friendlyAccountLabel == "It Oneone Build")
    }

    @Test("Codex account names prefer a non-empty override")
    func codexDisplayName() {
        let home = URL(fileURLWithPath: "/tmp/codex-work")
        #expect(
            CodexAccount(home: home, isImplicit: false, customName: "Work").displayName == "Work")
        #expect(
            CodexAccount(home: home, isImplicit: false, customName: "  ").displayName
                == "codex-work")
    }

    @Test("Provider reading state keeps value, timestamp, and error coherent")
    func providerReadingState() {
        let date = Date(timeIntervalSince1970: 123)
        let current = ReadingState<String>.current(value: "ok", polledAt: date)
        #expect(current.value == "ok")
        #expect(current.lastPolledAt == date)
        #expect(current.error == nil)
        #expect(!current.isStale)

        let stale = ReadingState<String>.stale(value: "old", polledAt: date, error: "offline")
        #expect(stale.value == "old")
        #expect(stale.lastPolledAt == date)
        #expect(stale.error == "offline")
        #expect(stale.isStale)
    }

    @Test("Chunking preserves order and the final partial chunk")
    func chunking() {
        #expect(Array(1...7).chunked(into: 3) == [[1, 2, 3], [4, 5, 6], [7]])
    }

    @MainActor
    @Test("Successful empty OAuth enrichment clears stale optional fields")
    func emptyOAuthEnrichmentClearsStaleValues() {
        var snapshot = ClaudeUsageSnapshot(
            parserVersion: "test",
            createdAt: Date(timeIntervalSince1970: 100),
            source: SourceInfo(cliPath: "statusline", command: "read"),
            account: AccountInfo(email: "person@example.com", plan: "Max"),
            limits: LimitInfo(
                currentWeekOpus: LimitWindow(percentUsed: 81),
                scopedWeekly: [
                    ScopedLimitWindow(
                        id: "seven_day_sonnet", window: LimitWindow(percentUsed: 42))
                ],
                extraUsage: ExtraUsage(isEnabled: true, usedCredits: 500)
            ),
            state: SnapshotState(status: .ok, severity: .normal)
        )
        let enrichment = OAuthPipeline.OAuthEnrichment(
            opus: nil,
            scopedWeekly: nil,
            extraUsage: nil,
            plan: nil
        )

        AppState.apply(enrichment, to: &snapshot)

        #expect(snapshot.limits.currentWeekOpus == nil)
        #expect(snapshot.limits.scopedWeekly == nil)
        #expect(snapshot.limits.extraUsage == nil)
        #expect(snapshot.account == AccountInfo(email: "person@example.com"))
    }

    @MainActor
    @Test("OAuth enrichment keeps observation time across failure and recovery")
    func oauthEnrichmentLifecycle() {
        let firstObservation = Date(timeIntervalSince1970: 100)
        let failedAttempt = Date(timeIntervalSince1970: 200)
        let recoveredObservation = Date(timeIntervalSince1970: 300)
        let initialValue = OAuthPipeline.OAuthEnrichment(
            opus: LimitWindow(percentUsed: 81),
            scopedWeekly: nil,
            extraUsage: nil,
            plan: "Max"
        )
        let recoveredValue = OAuthPipeline.OAuthEnrichment(
            opus: nil,
            scopedWeekly: nil,
            extraUsage: nil,
            plan: nil
        )

        let current = AppState.updatedOAuthEnrichmentReading(
            previous: nil,
            result: .success(initialValue),
            now: firstObservation
        )
        #expect(current.value == initialValue)
        #expect(current.lastPolledAt == firstObservation)
        #expect(current.error == nil)
        #expect(!current.isStale)

        let stale = AppState.updatedOAuthEnrichmentReading(
            previous: current,
            result: .unavailable(.networkError),
            now: failedAttempt
        )
        #expect(stale.value == initialValue)
        #expect(stale.lastPolledAt == firstObservation)
        #expect(stale.error == SourceAttempt.Reason.networkError.rawValue)
        #expect(stale.isStale)

        let recovered = AppState.updatedOAuthEnrichmentReading(
            previous: stale,
            result: .success(recoveredValue),
            now: recoveredObservation
        )
        #expect(recovered.value == recoveredValue)
        #expect(recovered.lastPolledAt == recoveredObservation)
        #expect(recovered.error == nil)
        #expect(!recovered.isStale)
    }

    @MainActor
    @Test("OAuth enrichment failure without a cache is failed, not stale")
    func oauthEnrichmentInitialFailure() {
        let failed = AppState.updatedOAuthEnrichmentReading(
            previous: nil,
            result: .unavailable(.credentialsUnavailable),
            now: Date(timeIntervalSince1970: 200)
        )

        #expect(failed.value == nil)
        #expect(failed.lastPolledAt == nil)
        #expect(failed.error == SourceAttempt.Reason.credentialsUnavailable.rawValue)
        #expect(!failed.isStale)
    }

    @Test("Energy bar pace marker stays centered and inside the track")
    func energyBarPaceMarker() {
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: -1) == 0)
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: 0.5) == 49)
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: 2) == 98)
        #expect(energyBarMarkerOffset(width: 1, expectedFraction: 0.5) == 0)
    }

    @MainActor
    @Test("Memory pressure invokes rebuildable cache trimming")
    func memoryPressureTrimsCaches() {
        var trimCalls = 0
        let expected = MemoryPressureTrimSummary(costEntries: 12, activityEntries: 7)
        let monitor = MemoryPressureMonitor(
            trimCaches: {
                trimCalls += 1
                return expected
            },
            releaseFreeMallocPages: {})

        let result = monitor.handleMemoryPressureForTesting()

        #expect(trimCalls == 1)
        #expect(result == expected)
        #expect(result.total == 19)
    }

    @MainActor
    @Test("Advisory service refresh is coalesced and publishes independently")
    func serviceStatusRefreshIsIndependent() async {
        let fetcher = SuspendedStatusFetcher()
        let state = AppState(
            pipeline: UnusedPipeline(),
            serviceStatusFetcher: { await fetcher.fetch() }
        )

        state.scheduleServiceStatusRefresh(generation: 0)
        state.scheduleServiceStatusRefresh(generation: 0)

        for _ in 0..<100 {
            if await fetcher.callCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await fetcher.callCount == 1)
        #expect(state.serviceStatus == nil)

        let expected = ServiceStatus(level: .major, description: "Partial outage")
        await fetcher.finish(with: expected)
        for _ in 0..<100 {
            if state.serviceStatus != nil { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(state.serviceStatus == expected)
    }
}
