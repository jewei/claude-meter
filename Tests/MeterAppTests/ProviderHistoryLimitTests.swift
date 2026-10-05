import Testing

@testable import MeterApp
@testable import ProviderCursor

/// A provider cannot import MeterApp, so it keeps its own copy of the app's history limit to
/// plan its time. This test keeps both the same.
@Suite struct ProviderHistoryLimitTests {
    @Test func cursorPlansWithTheStoreHistoryLimit() {
        #expect(CursorAPI.appHistoryLimit == UsageStore.historyDeadline)
    }
}
