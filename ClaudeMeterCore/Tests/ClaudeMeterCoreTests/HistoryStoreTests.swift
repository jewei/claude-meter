import XCTest
@testable import ClaudeMeterCore

final class HistoryStoreTests: XCTestCase {

    private var dir: URL!
    private var store: HistoryStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try! HistoryStore(directory: dir)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testAppendAndFetch() throws {
        let rec = makeRecord(sessionPct: 25, weekPct: 60)
        try store.append(rec)
        let fetched = try store.fetch()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].sessionPercent, 25)
        XCTAssertEqual(fetched[0].weekPercent, 60)
    }

    func testFetchSinceFilters() throws {
        let past = Date().addingTimeInterval(-7200)
        let now  = Date()
        try store.append(makeRecord(createdAt: past, sessionPct: 10))
        try store.append(makeRecord(createdAt: now,  sessionPct: 50))
        let recent = try store.fetch(since: Date().addingTimeInterval(-3600))
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].sessionPercent, 50)
    }

    func testPrune() throws {
        let shortRetention = try HistoryStore(directory: dir, retentionDays: 30)
        let old   = Date().addingTimeInterval(-86400 * 31)
        let fresh = Date()
        try shortRetention.append(makeRecord(createdAt: old,   sessionPct: 1))
        try shortRetention.append(makeRecord(createdAt: fresh, sessionPct: 2))
        let remaining = try shortRetention.fetch()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].sessionPercent, 2)
    }

    func testAppendPrunesByRetentionDays() throws {
        let shortRetention = try HistoryStore(directory: dir, retentionDays: 7)
        try shortRetention.append(makeRecord(
            createdAt: Date().addingTimeInterval(-86400 * 10),
            sessionPct: 5
        ))
        try shortRetention.append(makeRecord(sessionPct: 10))
        let remaining = try shortRetention.fetch()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].sessionPercent, 10)
    }

    func testRecordCount() throws {
        try store.append(makeRecord(sessionPct: 1))
        try store.append(makeRecord(sessionPct: 2))
        XCTAssertEqual(try store.recordCount(), 2)
    }

    func testCSVExport() throws {
        try store.append(makeRecord(sessionPct: 42, weekPct: 88))
        let csv = try store.exportCSV()
        XCTAssert(csv.hasPrefix("created_at,session_percent"))
        XCTAssert(csv.contains("42.00"))
        XCTAssert(csv.contains("88.00"))
        XCTAssert(csv.contains("normal"))
    }

    func testJSONExport() throws {
        try store.append(makeRecord(sessionPct: 10, weekPct: nil))
        let json = try store.exportJSON()
        XCTAssertFalse(json == "[]", "JSON should not be empty")
        XCTAssert(json.contains("sessionPercent"), "expected sessionPercent key in JSON")
        // JSONEncoder omits nil optionals so weekPercent is absent when nil
        XCTAssertFalse(json.contains("weekPercent"), "weekPercent should be omitted when nil")
        XCTAssert(json.contains("severity"), "expected severity key in JSON")
    }

    func testNullableFieldsRoundTrip() throws {
        let rec = HistoryRecord(
            createdAt: Date(),
            sessionPercent: nil,
            weekPercent: nil,
            sessionResetsAt: nil,
            weekResetsAt: nil,
            severity: "unknown",
            model: nil
        )
        try store.append(rec)
        let fetched = try store.fetch()
        XCTAssertNil(fetched[0].sessionPercent)
        XCTAssertNil(fetched[0].weekPercent)
        XCTAssertNil(fetched[0].model)
    }

    // MARK: - Helpers

    private func makeRecord(
        createdAt: Date = Date(),
        sessionPct: Double?,
        weekPct: Double? = nil
    ) -> HistoryRecord {
        HistoryRecord(
            createdAt: createdAt,
            sessionPercent: sessionPct,
            weekPercent: weekPct,
            sessionResetsAt: nil,
            weekResetsAt: nil,
            severity: "normal",
            model: nil
        )
    }
}
