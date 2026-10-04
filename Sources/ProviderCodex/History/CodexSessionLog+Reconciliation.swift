import Foundation
import MeterPlatform

extension CodexSessionLog {
    /// The records that this session owns, and whether some tokens could not be resolved.
    ///
    /// A fork or subagent counts only the events after its owned boundary, measured from the
    /// counters that it inherited. Without a boundary the session counts nothing and is
    /// partial, so inherited tokens are never counted twice.
    func ownedRecords(parent: CodexSessionLog?) -> (records: [TokenRecord], isPartial: Bool) {
        guard hasMetadata, !invalidOwnership else { return ([], true) }
        let boundary = needsOwnedBoundary ? ownedBoundary(parent: parent) : (0, .zero)
        guard let (start, baseline) = boundary else { return ([], true) }
        var walk = CounterWalk(baseline: baseline, isPartial: hasInvalidCounters)
        for event in events[start...] { walk.add(event) }
        return (walk.records, walk.isPartial)
    }

    /// The first owned event and the counters that the inherited history had reached.
    private func ownedBoundary(
        parent: CodexSessionLog?
    ) -> (start: Int, baseline: CodexTokenCounts)? {
        if let ordinal = historyStartOrdinal {
            guard let index = events.firstIndex(where: { ($0.ordinal ?? -1) >= ordinal }) else {
                return nil
            }
            let first = events[index]
            if let baseline = events[..<index].last(where: { $0.total != nil })?.total {
                // A counter that restarted at the boundary owns its whole total.
                if let total = first.total, total == first.last, !total.covers(baseline) {
                    return (index, .zero)
                }
                return (index, baseline)
            }
            if let total = first.total, let last = first.last, total.covers(last) {
                return (index, total.subtracting(last))
            }
            if first.total == nil, first.last != nil { return (index, .zero) }
            return nil
        }
        // A fork without an ordinal starts where its counters continue the parent's.
        guard let parent, !parent.hasInvalidCounters, !parent.invalidOwnership, let forkDate,
            let baseline = parent.events.last(where: { $0.date <= forkDate && $0.total != nil })?
                .total,
            let index = events.firstIndex(where: { event in
                guard event.date >= forkDate, let total = event.total, let last = event.last,
                    total.covers(last)
                else { return false }
                return total.subtracting(last) == baseline
            })
        else { return nil }
        return (index, baseline)
    }
}

/// Turns cumulative counters into records.
///
/// Only growth over the highest counters seen so far counts, limited by the event's own
/// `last` usage. A repeated response ID counts once. An event with only `last` usage counts
/// once per turn, response, and value.
private struct CounterWalk {
    private struct LastOnlyKey: Hashable {
        let turnID: String?
        let responseID: String?
        let counts: CodexTokenCounts
    }

    let baseline: CodexTokenCounts
    private(set) var isPartial: Bool
    private(set) var records: [TokenRecord] = []
    private var watermark: CodexTokenCounts
    private var responses: [String: CodexTokenCounts] = [:]
    private var lastOnly: Set<LastOnlyKey> = []

    init(baseline: CodexTokenCounts, isPartial: Bool) {
        self.baseline = baseline
        self.isPartial = isPartial
        watermark = baseline
    }

    mutating func add(_ event: CodexSessionLog.Event) {
        if let id = event.responseID, let previous = responses[id] {
            if let last = event.last, last != previous { isPartial = true }
            if let total = event.total { watermark = watermark.maximum(total) }
            return
        }
        let delta: CodexTokenCounts
        if let total = event.total {
            if !total.covers(watermark), !baseline.covers(total) { isPartial = true }
            let growth = total.subtracting(watermark)
            watermark = watermark.maximum(total)
            if let last = event.last {
                delta = growth.minimum(last)
                if !last.covers(growth) { isPartial = true }
            } else {
                // A jump in the cumulative counters can cover requests with unknown dates.
                delta = growth
                if growth != .zero { isPartial = true }
            }
        } else if let last = event.last {
            let key = LastOnlyKey(turnID: event.turnID, responseID: event.responseID, counts: last)
            guard lastOnly.insert(key).inserted else {
                isPartial = true
                return
            }
            if event.responseID == nil { isPartial = true }
            guard let next = watermark.adding(last) else {
                isPartial = true
                return
            }
            delta = last
            watermark = next
        } else {
            return
        }
        if let id = event.responseID { responses[id] = event.last ?? delta }
        if let count = delta.total {
            records.append(TokenRecord(date: event.date, count: count))
        } else {
            isPartial = true
        }
    }
}
