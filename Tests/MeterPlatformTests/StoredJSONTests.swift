import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

/// The JSON that the app writes to disk and to `UserDefaults`.
@Suite struct StoredJSONTests {
    private struct Stamp: Codable, Equatable {
        let date: Date
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder.meter.decode(Value.self, from: JSONEncoder.meter.encode(value))
    }

    @Test func datesKeepTheirMilliseconds() throws {
        let date = Date.reference(0.75)
        let data = try JSONEncoder.meter.encode(Stamp(date: date))
        #expect(String(decoding: data, as: UTF8.self) == #"{"date":"2026-10-04T12:00:00.750Z"}"#)
        #expect(try roundTrip(Stamp(date: date)) == Stamp(date: date))

        // A whole second keeps the format that earlier versions read.
        let whole = try JSONEncoder.meter.encode(Stamp(date: .reference()))
        #expect(String(decoding: whole, as: UTF8.self) == #"{"date":"2026-10-04T12:00:00Z"}"#)

        let store = MemoryStore()
        store.setValue(Stamp(date: date), forKey: "deadline")
        #expect(store.value(Stamp.self, forKey: "deadline") == Stamp(date: date))
    }

    @Test func datesWrittenWithoutFractionsStillLoad() throws {
        let data = Data(#"{"date":"2026-10-04T14:00:00+02:00"}"#.utf8)
        #expect(try JSONDecoder.meter.decode(Stamp.self, from: data) == Stamp(date: .reference()))
        let invalid = Data(#"{"date":"yesterday"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder.meter.decode(Stamp.self, from: invalid)
        }
    }

    @Test func providerUsageRoundTrips() throws {
        let account = AccountUsage(
            id: "work", name: "Work", plan: "Max 20x",
            windows: [
                QuotaWindow(
                    id: "five_hour", title: "Session", kind: .session, usedPercent: 120,
                    resetsAt: .reference(.hours(2.5)))
            ],
            balances: [
                Balance(
                    kind: .extraUsage, amount: Decimal(string: "12.34"),
                    limit: Decimal(string: "100.01"), unit: .currency("USD"), isPaused: true),
                Balance(kind: .credits, amount: nil, unit: .credits, isUnlimited: true),
            ],
            resetAllowance: ResetAllowance(
                available: 2,
                resets: [
                    .init(title: "Reset", expiresAt: .reference(.days(3))),
                    .init(title: "Unknown expiry", expiresAt: nil),
                ]),
            observedAt: .reference(0.25), isStale: true,
            issue: UsageIssue("Try again later.", retryAt: .reference(60), needsAction: true),
            attemptedAt: .reference(1.5), owner: .identity("abc"), sharesLogin: true)
        let usage = ProviderUsage(provider: .claude, accounts: [account])
        #expect(try roundTrip(usage) == usage)
        #expect(try roundTrip(AccountOwner.credential("x")) == .credential("x"))
    }
}
