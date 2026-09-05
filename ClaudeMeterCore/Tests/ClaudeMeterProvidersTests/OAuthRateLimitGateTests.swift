import Foundation
import Testing

@testable import ClaudeMeterProviders

@Suite("Persistent Claude usage backoff")
struct OAuthRateLimitGateTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private final class MemoryStorage: @unchecked Sendable {
        var data: Data?
        var failWrites = false

        var storage: OAuthRateLimitGate.Storage {
            .init(
                load: { self.data },
                save: { data in
                    if self.failWrites { throw CocoaError(.fileWriteUnknown) }
                    self.data = data
                })
        }
    }

    @Test func relaunchKeepsDeadlineAndExpiryRemovesIt() {
        let storage = MemoryStorage()
        let first = OAuthRateLimitGate()
        first.enablePersistence(storage.storage, now: now)
        first.recordRateLimit(retryAfter: now.addingTimeInterval(3600), now: now)

        let relaunched = OAuthRateLimitGate()
        relaunched.enablePersistence(storage.storage, now: now.addingTimeInterval(60))
        #expect(relaunched.isRateLimited(now: now.addingTimeInterval(3599)))
        #expect(relaunched.deadline(now: now) == now.addingTimeInterval(3600))
        #expect(!relaunched.isRateLimited(now: now.addingTimeInterval(3600)))
        #expect(storage.data == nil)
    }

    @Test func repeatedLoadsAndShorterResponsesCannotExtendOrShortenDeadline() {
        let storage = MemoryStorage()
        let first = OAuthRateLimitGate()
        first.enablePersistence(storage.storage, now: now)
        first.recordRateLimit(retryAfter: now.addingTimeInterval(3600), now: now)
        for offset in [30.0, 120.0, 300.0] {
            let gate = OAuthRateLimitGate()
            let time = now.addingTimeInterval(offset)
            gate.enablePersistence(storage.storage, now: time)
            gate.recordRateLimit(retryAfter: nil, now: time)
            #expect(gate.deadline(now: time) == now.addingTimeInterval(3600))
        }
    }

    @Test func concurrentWritesKeepLongestDeadlineOnRelaunch() async {
        let storage = MemoryStorage()
        let gate = OAuthRateLimitGate()
        gate.enablePersistence(storage.storage, now: now)
        await withTaskGroup(of: Void.self) { group in
            for delay in [60.0, 3600.0, 120.0, 1800.0] {
                group.addTask {
                    gate.recordRateLimit(retryAfter: now.addingTimeInterval(delay), now: now)
                }
            }
        }
        let relaunched = OAuthRateLimitGate()
        relaunched.enablePersistence(storage.storage, now: now)
        #expect(relaunched.deadline(now: now) == now.addingTimeInterval(3600))
    }

    @Test func corruptExpiredAndOversizedRecordsAreRemoved() throws {
        let records = [
            OAuthRateLimitGate.Record(recordedAt: now, until: now),
            .init(recordedAt: now, until: now.addingTimeInterval(86401)),
            .init(recordedAt: now.addingTimeInterval(500), until: now.addingTimeInterval(100)),
            .init(recordedAt: .distantPast, until: now.addingTimeInterval(100)),
        ]
        let encoded = try records.map { try JSONEncoder().encode($0) }
        for data in encoded + [Data("invalid".utf8), Data(repeating: 32, count: 513)] {
            let storage = MemoryStorage()
            storage.data = data
            let gate = OAuthRateLimitGate()
            gate.enablePersistence(storage.storage, now: now)
            #expect(!gate.isRateLimited(now: now))
            #expect(storage.data == nil)
        }
    }

    @Test func nonFiniteAndOutOfRangeDatesAreInvalid() {
        for date in [
            Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: 32_503_680_000),
        ] {
            #expect(!OAuthRateLimitGate.Record(recordedAt: now, until: date).isValid(asOf: now))
        }
    }

    @Test func clockChangesRemainBoundedAndReadsDoNotClearState() {
        let storage = MemoryStorage()
        let gate = OAuthRateLimitGate()
        gate.enablePersistence(storage.storage, now: now)
        gate.recordRateLimit(retryAfter: now.addingTimeInterval(3600), now: now)
        #expect(gate.deadline(now: now.addingTimeInterval(4000)) == nil)
        #expect(gate.isRateLimited(now: now))
        let smallRollback = OAuthRateLimitGate()
        smallRollback.enablePersistence(storage.storage, now: now.addingTimeInterval(-300))
        #expect(smallRollback.deadline(now: now) == now.addingTimeInterval(3600))
        let largeRollback = OAuthRateLimitGate()
        largeRollback.enablePersistence(storage.storage, now: now.addingTimeInterval(-86400))
        #expect(!largeRollback.isRateLimited(now: now.addingTimeInterval(-86400)))
    }

    @Test func writeFailureKeepsMemoryBlockAndServerDelayIsCapped() {
        let storage = MemoryStorage()
        storage.failWrites = true
        let gate = OAuthRateLimitGate()
        gate.enablePersistence(storage.storage, now: now)
        gate.recordRateLimit(retryAfter: now.addingTimeInterval(1_000_000), now: now)
        #expect(gate.deadline(now: now) == now.addingTimeInterval(86400))
        #expect(gate.isRateLimited(now: now.addingTimeInterval(3600)))
    }

    @Test func isolatedDefaultsRoundTrip() throws {
        let name = "ClaudeBackoffTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = OAuthRateLimitGate()
        first.enablePersistence(.defaults(defaults), now: now)
        first.recordRateLimit(retryAfter: nil, now: now)
        let relaunched = OAuthRateLimitGate()
        relaunched.enablePersistence(.defaults(defaults), now: now)
        #expect(relaunched.deadline(now: now) == now.addingTimeInterval(60))
    }

    @Test func loadFailureDoesNotEraseStoredStateOrAnExistingMemoryBlock() {
        let storage = MemoryStorage()
        storage.data = Data("unreadable saved state".utf8)
        let gate = OAuthRateLimitGate()
        gate.recordRateLimit(retryAfter: now.addingTimeInterval(600), now: now)
        gate.enablePersistence(
            .init(
                load: { throw CocoaError(.fileReadUnknown) },
                save: { storage.data = $0 }), now: now)
        #expect(gate.deadline(now: now) == now.addingTimeInterval(600))
        #expect(storage.data == Data("unreadable saved state".utf8))
    }
}
