import Foundation
import MeterPlatform

/// Keeps one record per completed turn and model from one Grok Build `updates.jsonl` file.
///
/// Only `turn_completed` updates carry final usage, so unfinished turns are absent, not
/// partial. The event ID and the model name identify a record, so a turn copied to another
/// session file counts once.
struct GrokHistoryParser: HistoryFileParser {
    private(set) var records = TokenRecordSet()
    private(set) var isPartial = false

    init() {}

    var recordCount: Int { records.count }

    mutating func append(_ line: Data, offset: Int64, decoder: JSONDecoder) {
        guard let entry = try? decoder.decode(GrokUpdateLine.self, from: line) else {
            isPartial = true
            return
        }
        guard let update = entry.update, update.isCompletedTurn, let models = update.models
        else { return }
        guard let date = entry.date else {
            isPartial = true
            return
        }
        let eventID = entry.meta?.eventID?.value
        if eventID == nil { isPartial = true }
        for (model, usage) in models {
            // Total tokens are input plus output; cache and reasoning are inside them.
            guard
                let count = TokenRecord.sum([
                    usage.input?.value, HistoryJSON.Count.orZero(usage.output),
                ])
            else {
                isPartial = true
                continue
            }
            let key = eventID.map { "\($0.utf8.count):\($0):\(model)" }
            records.insert(TokenRecord(date: date, count: count), key: key)
        }
    }
}
