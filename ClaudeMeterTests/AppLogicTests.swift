import Foundation
import Testing

@testable import ClaudeMeter

@Suite("App logic")
struct AppLogicTests {
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
}
