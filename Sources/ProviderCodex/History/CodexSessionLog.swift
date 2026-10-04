import Foundation
import MeterPlatform

/// The token counters and ownership fields of one Codex rollout file.
///
/// Codex writes cumulative `token_count` events. A fork or a subagent file starts with a copy
/// of its parent's history, so the file also keeps the fields that show where its own history
/// begins. Reconciliation turns the events into records later, when the parent is known.
struct CodexSessionLog: HistoryFileParser {
    /// One `token_count` event.
    struct Event: Hashable, Sendable {
        let date: Date
        let total: CodexTokenCounts?
        let last: CodexTokenCounts?
        let ordinal: Int64?
        let responseID: String?
        let turnID: String?
    }

    private(set) var sessionID: String?
    private(set) var parentID: String?
    private(set) var forkDate: Date?
    private(set) var historyStartOrdinal: Int64?
    /// The file copies parent history, so only events after an owned boundary count.
    private(set) var needsOwnedBoundary = false
    /// An ownership field has an invalid value, so no event can be assigned safely.
    private(set) var invalidOwnership = false
    private(set) var hasMetadata = false
    /// A `token_count` event had an invalid date or counter, so its tokens are missing.
    private(set) var hasInvalidCounters = false
    private(set) var hasMalformedLines = false
    private(set) var events: [Event] = []
    private var turnID: String?

    init() {}

    var recordCount: Int { events.count }

    var isPartial: Bool { hasInvalidCounters || hasMalformedLines }

    mutating func append(_ line: Data, offset: Int64, decoder: JSONDecoder) {
        guard let entry = try? decoder.decode(CodexLogLine.self, from: line) else {
            hasMalformedLines = true
            return
        }
        switch entry.type {
        case "session_meta": readMetadata(entry)
        case "turn_context": turnID = entry.payload.turnID
        case "event_msg": readEvent(entry)
        default: break
        }
    }

    /// True when both files describe the same session with the same ownership.
    func hasSameOwnership(as other: CodexSessionLog) -> Bool {
        sessionID == other.sessionID && parentID == other.parentID
            && historyStartOrdinal == other.historyStartOrdinal
            && needsOwnedBoundary == other.needsOwnedBoundary
            && invalidOwnership == other.invalidOwnership
    }

    private mutating func readMetadata(_ entry: CodexLogLine) {
        let payload = entry.payload
        // A subagent file repeats its parent's metadata after its own.
        if hasMetadata, payload.id != sessionID {
            needsOwnedBoundary = true
            return
        }
        hasMetadata = true
        sessionID = payload.id
        for parent in payload.parents {
            if let id = parent.value {
                parentID = id
            } else {
                invalidOwnership = true
            }
        }
        if let source = payload.source, source.isSubagent {
            needsOwnedBoundary = true
            parentID = parentID ?? source.parentID
        }
        if let ordinal = payload.historyStartOrdinal {
            historyStartOrdinal = ordinal.value
            if ordinal.value == nil { invalidOwnership = true }
        }
        forkDate = payload.timestamp?.date ?? entry.timestamp?.date
        needsOwnedBoundary = needsOwnedBoundary || parentID != nil || historyStartOrdinal != nil
    }

    private mutating func readEvent(_ entry: CodexLogLine) {
        let payload = entry.payload
        if payload.type == "task_started" { turnID = payload.turnID }
        // `info` is null until the first response finishes.
        guard payload.type == "token_count", let info = payload.info else { return }
        guard let date = entry.timestamp?.date else {
            hasInvalidCounters = true
            return
        }
        if info.total.map({ $0.counts == nil }) == true
            || info.last.map({ $0.counts == nil }) == true
        {
            hasInvalidCounters = true
            return
        }
        let total = info.total?.counts
        let last = info.last?.counts
        guard total != nil || last != nil else { return }
        events.append(
            Event(
                date: date, total: total, last: last, ordinal: entry.ordinal?.value,
                responseID: info.responseID ?? payload.responseID,
                turnID: payload.turnID ?? turnID))
    }
}
