import Foundation
import MeterDomain
import MeterPlatform

/// The fields of one Grok Build `updates.jsonl` line that history reads. A line is a
/// JSON-RPC notification; `update` and `_meta` sit in `params` or at the top level.
struct GrokUpdateLine: Decodable {
    struct Update: Decodable {
        let isCompletedTurn: Bool
        /// Model name → usage, from `usage.modelUsage`.
        let models: [String: ModelUsage]?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            isCompletedTurn = (container.lenient(.sessionUpdate) as String?) == "turn_completed"
            let usage: Usage? = container.lenient(.usage)
            models = usage?.models
        }

        private enum Keys: String, CodingKey {
            case sessionUpdate, usage
        }
    }

    struct Usage: Decodable {
        let models: [String: ModelUsage]?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            models = container.lenient(.modelUsage)
        }

        private enum Keys: String, CodingKey {
            case modelUsage
        }
    }

    /// Tokens of one model in one turn. Cache and reasoning counts are subsets of input and
    /// output, so they are not read. Decoding never fails; a value that is not an object has no
    /// input count.
    struct ModelUsage: Decodable {
        let input: HistoryJSON.Count?
        let output: HistoryJSON.Count?

        init(from decoder: any Decoder) {
            let container = try? decoder.container(keyedBy: Keys.self)
            input = container?.lenient(.input)
            output = container?.lenient(.output)
        }

        private enum Keys: String, CodingKey {
            case input = "inputTokens"
            case output = "outputTokens"
        }
    }

    struct Meta: Decodable {
        let eventID: HistoryJSON.Text?
        let agentTimestampMilliseconds: HistoryJSON.Number?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            eventID = container.lenient(.eventID)
            agentTimestampMilliseconds = container.lenient(.agentTimestamp)
        }

        private enum Keys: String, CodingKey {
            case eventID = "eventId"
            case agentTimestamp = "agentTimestampMs"
        }
    }

    private struct Params: Decodable {
        let update: Update?
        let meta: Meta?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            update = container.lenient(.update)
            meta = container.lenient(.meta)
        }
    }

    private enum Keys: String, CodingKey {
        case params, update, timestamp
        case meta = "_meta"
    }

    let update: Update?
    let meta: Meta?
    let timestamp: HistoryJSON.Timestamp?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let params: Params? = container.lenient(.params)
        update = params?.update ?? container.lenient(.update)
        meta = params?.meta ?? container.lenient(.meta)
        timestamp = container.lenient(.timestamp)
    }

    /// The event time: `_meta.agentTimestampMs`, else the top-level `timestamp`.
    var date: Date? {
        if let milliseconds = meta?.agentTimestampMilliseconds?.value,
            let date = DateBounds.date(secondsSince1970: milliseconds / 1000)
        {
            return date
        }
        return timestamp?.date
    }
}
