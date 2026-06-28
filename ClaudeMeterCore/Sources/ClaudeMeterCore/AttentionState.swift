import Foundation

/// One Claude Code session currently waiting on the user.
public struct WaitingSession: Sendable, Equatable, Identifiable {
    public let accountKey: String
    public let sessionId: String
    public let projectName: String?
    /// The latest event kind for this session (`stop` = turn done, `notification`
    /// = needs permission / idle).
    public let kind: SessionEvent.Kind
    public let message: String?
    public let since: Date

    public var id: String { "\(accountKey)/\(sessionId)" }

    public init(
        accountKey: String, sessionId: String, projectName: String?, kind: SessionEvent.Kind,
        message: String?, since: Date
    ) {
        self.accountKey = accountKey
        self.sessionId = sessionId
        self.projectName = projectName
        self.kind = kind
        self.message = message
        self.since = since
    }
}

/// Aggregate "who needs me" state across all sessions/accounts — drives the
/// menu-bar attention bolt and the popover's waiting list. A pure value type with
/// an event reducer so the state machine is testable without the app.
public struct AttentionState: Sendable, Equatable {
    public var waiting: [WaitingSession]

    public init(waiting: [WaitingSession] = []) { self.waiting = waiting }

    public static let none = AttentionState()

    public var needsAttention: Bool { !waiting.isEmpty }
    public var count: Int { waiting.count }

    /// Folds newly-drained events in: each `Stop`/`Notification` with a session id
    /// marks that session as waiting (latest event wins per session). Other kinds
    /// and session-less events are ignored. Result is ordered oldest-first.
    public func applying(_ events: [SessionEvent], now: Date = Date()) -> AttentionState {
        var byID = Dictionary(uniqueKeysWithValues: waiting.map { ($0.id, $0) })
        for event in events {
            guard event.kind == .stop || event.kind == .notification,
                let sessionId = event.sessionId, !sessionId.isEmpty
            else { continue }
            let session = WaitingSession(
                accountKey: event.accountKey,
                sessionId: sessionId,
                projectName: event.projectName,
                kind: event.kind,
                message: event.message,
                since: event.capturedAt
            )
            byID[session.id] = session
        }
        return AttentionState(waiting: byID.values.sorted { $0.since < $1.since })
    }

    /// Everything handled — clears all waiting sessions (e.g. popover opened).
    public func cleared() -> AttentionState { .none }

    /// Clears one session (e.g. its terminal gained focus).
    public func clearing(id: String) -> AttentionState {
        AttentionState(waiting: waiting.filter { $0.id != id })
    }

    /// Drops sessions whose attention is older than `expiry` — a guard against a
    /// bolt that never clears (the user never opened the popover or focused the
    /// terminal, and v1 can't see the next turn start).
    public func pruned(now: Date = Date(), expiry: TimeInterval) -> AttentionState {
        AttentionState(waiting: waiting.filter { now.timeIntervalSince($0.since) < expiry })
    }
}
