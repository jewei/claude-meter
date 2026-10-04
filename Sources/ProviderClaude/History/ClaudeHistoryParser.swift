import Foundation
import MeterPlatform

/// Keeps one record per Claude response from the assistant lines of one session file.
///
/// Claude Code writes a line per content block, and each line repeats the cumulative usage
/// of its response. Request and message IDs identify the response, so one record is kept per
/// response: the one with the larger count, then the earlier date
/// (``TokenRecord/replaces(_:)``). Copies in other files count once by the same rule.
struct ClaudeHistoryParser: HistoryFileParser {
    private(set) var records = TokenRecordSet()
    private(set) var isPartial = false

    init() {}

    var recordCount: Int { records.count }

    mutating func append(_ line: Data, offset: Int64, decoder: JSONDecoder) {
        guard let entry = try? decoder.decode(ClaudeLogLine.self, from: line) else {
            isPartial = true
            return
        }
        guard entry.isAssistant, let usage = entry.message?.usage else { return }
        guard let date = entry.timestamp?.date, let count = usage.total else {
            isPartial = true
            return
        }
        // Length-prefix the request so that no pair of IDs can join into the same key.
        let request = entry.requestID ?? ""
        let key = entry.message?.id?.value.map { "\(request.utf8.count):\(request):\($0)" }
        if key == nil { isPartial = true }
        records.insert(TokenRecord(date: date, count: count), key: key)
    }
}
