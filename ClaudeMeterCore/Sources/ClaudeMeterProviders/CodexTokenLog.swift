import Foundation

/// Counter reconciliation adapted from Claude Meter's former Codex cost reader.
/// Input includes cached tokens. Output includes reasoning tokens.
struct CodexTokenLog: Sendable {
    struct Counts: Equatable, Hashable, Sendable {
        var input: Int64
        var output: Int64
        static let zero = Counts(input: 0, output: 0)

        func contains(_ other: Self) -> Bool { input >= other.input && output >= other.output }
        func subtracting(_ other: Self) -> Self {
            Self(input: max(0, input - other.input), output: max(0, output - other.output))
        }
        func maximum(_ other: Self) -> Self {
            Self(input: max(input, other.input), output: max(output, other.output))
        }
        func minimum(_ other: Self) -> Self {
            Self(input: min(input, other.input), output: min(output, other.output))
        }
        func adding(_ other: Self) -> Self? {
            guard let input = TokenJSON.sum([input, other.input]),
                let output = TokenJSON.sum([output, other.output]),
                TokenJSON.sum([input, output]) != nil
            else { return nil }
            return Self(input: input, output: output)
        }
    }

    struct Event: Equatable, Sendable {
        let date: Date
        let total: Counts?
        let last: Counts?
        let ordinal: Int64?
        let responseID: String?
        let turnID: String?
    }

    var sessionID: String?
    var parentID: String?
    var forkDate: Date?
    var historyStartOrdinal: Int64?
    var needsOwnedBoundary = false
    var invalidOwnership = false
    var isPartial = false
    var events: [Event] = []
    private var turnID: String?
    private var sawMetadata = false

    mutating func append(_ object: [String: Any]) {
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "session_meta":
            let nextID =
                TokenJSON.string(payload["id"])
                ?? TokenJSON.string(payload["session_id"])
            if sawMetadata, nextID != sessionID {
                needsOwnedBoundary = true
                return
            }
            sawMetadata = true
            sessionID = nextID
            let parentKeys = [
                "forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId",
                "parent_thread_id",
            ]
            for key in parentKeys where payload[key] != nil && !(payload[key] is NSNull) {
                if let id = TokenJSON.string(payload[key]) {
                    parentID = id
                } else {
                    invalidOwnership = true
                }
            }
            if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                needsOwnedBoundary = true
                if let subagent = source["subagent"] as? [String: Any],
                    let spawn = subagent["thread_spawn"] as? [String: Any]
                {
                    parentID = parentID ?? TokenJSON.string(spawn["parent_thread_id"])
                }
            }
            if payload["source"] as? String == "subagent" { needsOwnedBoundary = true }
            if let raw = payload["subagent_history_start_ordinal"], !(raw is NSNull) {
                historyStartOrdinal = TokenJSON.count(raw)
                if historyStartOrdinal == nil { invalidOwnership = true }
            }
            forkDate = TokenJSON.date(payload["timestamp"]) ?? TokenJSON.date(object["timestamp"])
            needsOwnedBoundary = needsOwnedBoundary || parentID != nil || historyStartOrdinal != nil
        case "turn_context":
            turnID = TokenJSON.string(payload["turn_id"]) ?? TokenJSON.string(payload["turnId"])
        case "event_msg":
            if payload["type"] as? String == "task_started" {
                turnID = TokenJSON.string(payload["turn_id"]) ?? TokenJSON.string(payload["turnId"])
            }
            guard payload["type"] as? String == "token_count",
                let info = payload["info"] as? [String: Any]
            else { return }
            guard let date = TokenJSON.date(object["timestamp"]) else {
                isPartial = true
                return
            }
            let total = Self.counts(info["total_token_usage"])
            let last = Self.counts(info["last_token_usage"])
            if info["total_token_usage"] != nil && !(info["total_token_usage"] is NSNull)
                && total == nil
                || info["last_token_usage"] != nil && !(info["last_token_usage"] is NSNull)
                    && last == nil
            {
                isPartial = true
                return
            }
            guard total != nil || last != nil else { return }
            events.append(
                Event(
                    date: date, total: total, last: last,
                    ordinal: TokenJSON.count(object["ordinal"]),
                    responseID: TokenJSON.string(info["response_id"])
                        ?? TokenJSON.string(info["request_id"])
                        ?? TokenJSON.string(payload["response_id"])
                        ?? TokenJSON.string(payload["request_id"]),
                    turnID: TokenJSON.string(payload["turn_id"]) ?? turnID))
        default: break
        }
    }

    private static func counts(_ raw: Any?) -> Counts? {
        guard let raw = raw as? [String: Any],
            let input = TokenJSON.count(raw["input_tokens"]),
            let output = TokenJSON.count(raw["output_tokens"]),
            TokenJSON.sum([input, output]) != nil
        else { return nil }
        return Counts(input: input, output: output)
    }

    private func ownedSuffix(parent: Self?) -> (start: Int, baseline: Counts)? {
        if let ordinal = historyStartOrdinal,
            let index = events.firstIndex(where: { ($0.ordinal ?? -1) >= ordinal })
        {
            let first = events[index]
            if let baseline = events[..<index].last(where: { $0.total != nil })?.total {
                if let total = first.total, total == first.last, !total.contains(baseline) {
                    return (index, .zero)
                }
                return (index, baseline)
            }
            if let total = first.total, let last = first.last, total.contains(last) {
                return (index, total.subtracting(last))
            }
            if first.total == nil, first.last != nil { return (index, .zero) }
        }
        if historyStartOrdinal == nil, let parent, !parent.isPartial, !parent.invalidOwnership,
            let forkDate,
            let baseline = parent.events.last(where: { $0.date <= forkDate && $0.total != nil })?
                .total,
            let index = events.firstIndex(where: {
                guard $0.date >= forkDate, let total = $0.total, let last = $0.last,
                    total.contains(last)
                else { return false }
                return total.subtracting(last) == baseline
            })
        {
            return (index, baseline)
        }
        return nil
    }

    func reconciled(parent: Self?) -> (events: [TokenEvent], partial: Bool) {
        guard sawMetadata, !invalidOwnership else { return ([], true) }
        let ownership = needsOwnedBoundary ? ownedSuffix(parent: parent) : (0, Counts.zero)
        guard let (start, baseline) = ownership else { return ([], true) }
        var watermark = baseline
        var output: [TokenEvent] = []
        var partial = isPartial
        var responses: [String: Counts] = [:]
        var lastOnly = Set<LastIdentity>()
        for event in events.dropFirst(start) {
            if let id = event.responseID, let previous = responses[id] {
                if let last = event.last, last != previous { partial = true }
                if let total = event.total { watermark = watermark.maximum(total) }
                continue
            }
            let delta: Counts
            if let total = event.total {
                if !total.contains(watermark), !baseline.contains(total) { partial = true }
                let growth = total.subtracting(watermark)
                watermark = watermark.maximum(total)
                if let last = event.last {
                    delta = growth.minimum(last)
                    if !last.contains(growth) { partial = true }
                } else {
                    // A cumulative-only jump can cover requests with unknown dates.
                    // Keep the known increment visible, with partial coverage.
                    delta = growth
                    if growth != .zero { partial = true }
                }
            } else if let last = event.last {
                let key = LastIdentity(
                    turnID: event.turnID, responseID: event.responseID, counts: last)
                guard lastOnly.insert(key).inserted else {
                    partial = true
                    continue
                }
                if event.responseID == nil { partial = true }
                delta = last
                guard let next = watermark.adding(last) else {
                    partial = true
                    continue
                }
                watermark = next
            } else {
                continue
            }
            if let id = event.responseID { responses[id] = event.last ?? delta }
            if let count = TokenJSON.sum([delta.input, delta.output]) {
                output.append(TokenEvent(date: event.date, count: count))
            } else {
                partial = true
            }
        }
        return (output, partial)
    }

    private struct LastIdentity: Hashable {
        let turnID: String?
        let responseID: String?
        let counts: Counts
    }

    func sameOwnership(as other: Self) -> Bool {
        sessionID == other.sessionID && parentID == other.parentID
            && historyStartOrdinal == other.historyStartOrdinal
            && needsOwnedBoundary == other.needsOwnedBoundary
            && invalidOwnership == other.invalidOwnership
    }
}
