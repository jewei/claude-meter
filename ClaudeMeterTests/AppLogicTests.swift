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

    @Test("Energy bar pace marker stays centered and inside the track")
    func energyBarPaceMarker() {
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: -1) == 0)
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: 0.5) == 49)
        #expect(energyBarMarkerOffset(width: 100, expectedFraction: 2) == 98)
        #expect(energyBarMarkerOffset(width: 1, expectedFraction: 0.5) == 0)
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
