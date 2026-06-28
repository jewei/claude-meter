import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("AttentionState")
struct AttentionStateTests {
    private let now = Date(timeIntervalSince1970: 1_782_269_456)

    private func event(
        _ kind: SessionEvent.Kind, account: String = "claude", session: String?,
        project: String? = nil, at offset: TimeInterval = 0
    ) -> SessionEvent {
        SessionEvent(
            kind: kind, accountKey: account, sessionId: session,
            cwd: project.map { "/Users/x/\($0)" }, message: nil,
            capturedAt: now.addingTimeInterval(offset))
    }

    @Test func stopAndNotificationMarkSessionsWaiting() {
        let state = AttentionState.none.applying([
            event(.stop, session: "s1", project: "alpha"),
            event(.notification, account: "work", session: "s2", project: "beta"),
        ])
        #expect(state.needsAttention)
        #expect(state.count == 2)
        #expect(state.waiting.contains { $0.id == "claude/s1" && $0.projectName == "alpha" })
        #expect(state.waiting.contains { $0.id == "work/s2" && $0.kind == .notification })
    }

    @Test func latestEventPerSessionWins() {
        let state = AttentionState.none
            .applying([event(.notification, session: "s1", at: 0)])
            .applying([event(.stop, session: "s1", at: 10)])
        #expect(state.count == 1)
        #expect(state.waiting.first?.kind == .stop)
        #expect(state.waiting.first?.since == now.addingTimeInterval(10))
    }

    @Test func ignoresSessionlessAndOtherKinds() {
        let state = AttentionState.none.applying([
            event(.stop, session: nil),
            event(.other, session: "s9"),
        ])
        #expect(!state.needsAttention)
    }

    @Test func clearedAndClearingRemoveSessions() {
        let base = AttentionState.none.applying([
            event(.stop, session: "s1"), event(.stop, session: "s2"),
        ])
        #expect(base.clearing(id: "claude/s1").count == 1)
        #expect(base.cleared().waiting.isEmpty)
    }

    @Test func prunedDropsExpiredAttention() {
        let state = AttentionState.none.applying([
            event(.stop, session: "fresh", at: -60),
            event(.stop, session: "stale", at: -1200),
        ])
        let pruned = state.pruned(now: now, expiry: 600)
        #expect(pruned.count == 1)
        #expect(pruned.waiting.first?.sessionId == "fresh")
    }
}
