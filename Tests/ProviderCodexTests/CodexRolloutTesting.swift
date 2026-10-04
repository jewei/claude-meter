import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import ProviderCodex
import Testing

/// Builds Codex rollout lines and reads them back through ``CodexTokenHistory``.
protocol CodexRolloutTesting {
    var calendar: Calendar { get }
}

extension CodexRolloutTesting {
    func json(_ objects: [String: Any]...) throws -> String {
        try objects.map { object in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self) + "\n"
        }.joined()
    }

    func metadata(
        _ id: String, parent: String? = nil, ordinal: Any? = nil, extra: [String: Any] = [:]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": id, "timestamp": Date.reference(-5).ISO8601Format(), "cwd": "/secret/path",
        ]
        payload["forked_from_id"] = parent
        payload["subagent_history_start_ordinal"] = ordinal
        payload.merge(extra) { _, new in new }
        return [
            "type": "session_meta", "timestamp": Date.reference(-5).ISO8601Format(),
            "payload": payload,
        ]
    }

    /// A `token_count` event with cumulative `total` and per-response `last` usage.
    func event(
        total: (Int, Int)?, last: (Int, Int)?, at date: Date = .reference(),
        ordinal: Int = 0, id: String? = "response", extra: [String: Any] = [:]
    ) -> [String: Any] {
        func usage(_ counts: (Int, Int)) -> [String: Any] {
            [
                "input_tokens": counts.0, "output_tokens": counts.1,
                "cached_input_tokens": counts.0 / 2, "reasoning_output_tokens": counts.1 / 2,
                "total_tokens": counts.0 + counts.1,
            ].merging(extra) { _, new in new }
        }
        var info: [String: Any] = [:]
        info["total_token_usage"] = total.map(usage)
        info["last_token_usage"] = last.map(usage)
        info["response_id"] = id
        return [
            "type": "event_msg", "timestamp": date.ISO8601Format(), "ordinal": ordinal,
            "payload": ["type": "token_count", "info": info],
        ]
    }

    func history(_ homes: [String: TemporaryDirectory]) async throws
        -> ProviderTokenHistory
    {
        let roots = homes.map { HistoryRoot(account: AccountID($0.key), directory: $0.value.url) }
        return try await CodexTokenHistory(roots: { roots }, calendar: calendar)
            .history(now: .reference())
    }

    func tokens(
        _ history: ProviderTokenHistory, _ account: AccountID = "home",
        _ period: TokenPeriod = .today
    ) -> Int64? {
        history.history(for: account).tokens(in: period, now: .reference(), calendar: calendar)
    }
}
