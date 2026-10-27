import Foundation
import MeterPlatform

/// The fields of one Claude Code session line that history reads. The message content and
/// every other field are skipped, so no prompt or response text is kept.
struct ClaudeLogLine: Decodable {
    struct Message: Decodable {
        let id: HistoryJSON.Text?
        /// The API model ID, such as `claude-opus-5-5`. Prices the record.
        let model: HistoryJSON.Text?
        let usage: Usage?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            id = container.lenient(.id)
            model = container.lenient(.model)
            usage = container.lenient(.usage)
        }

        private enum Keys: String, CodingKey {
            case id, model, usage
        }
    }

    struct Usage: Decodable {
        let input: HistoryJSON.Count?
        let output: HistoryJSON.Count?
        let cacheRead: HistoryJSON.Count?
        let cacheWrite: HistoryJSON.Count?
        let cacheWriteSplit: CacheWriteSplit?
        /// `standard` or `fast`. Fast mode multiplies the price.
        let speed: HistoryJSON.Text?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            input = container.lenient(.input)
            output = container.lenient(.output)
            cacheRead = container.lenient(.cacheRead)
            cacheWrite = container.lenient(.cacheWrite)
            cacheWriteSplit = container.lenient(.cacheWriteSplit)
            speed = container.lenient(.speed)
        }

        /// Cache writes by lifetime: (5 minutes, 1 hour). Without the split, every write is a
        /// 5-minute write. Nil when a count is invalid.
        var cacheWrites: (fiveMinutes: Int64, oneHour: Int64)? {
            if let split = cacheWriteSplit, split.isPresent {
                guard let five = HistoryJSON.Count.orZero(split.fiveMinutes),
                    let hour = HistoryJSON.Count.orZero(split.oneHour)
                else { return nil }
                return (five, hour)
            }
            return HistoryJSON.Count.orZero(cacheWrite).map { ($0, 0) }
        }

        /// Input, output, cache-read, and cache-write tokens, or nil when a count is invalid or
        /// the sum overflows. Input and output are required; the cache counts default to zero.
        var total: Int64? {
            let write: Int64? =
                if let split = cacheWriteSplit, split.isPresent {
                    TokenRecord.sum([
                        HistoryJSON.Count.orZero(split.fiveMinutes),
                        HistoryJSON.Count.orZero(split.oneHour),
                    ])
                } else {
                    HistoryJSON.Count.orZero(cacheWrite)
                }
            return TokenRecord.sum([
                input?.value, output?.value, HistoryJSON.Count.orZero(cacheRead), write,
            ])
        }

        private enum Keys: String, CodingKey {
            case input = "input_tokens"
            case output = "output_tokens"
            case cacheRead = "cache_read_input_tokens"
            case cacheWrite = "cache_creation_input_tokens"
            case cacheWriteSplit = "cache_creation"
            case speed
        }
    }

    /// Cache writes split by lifetime. When either key is present, even as null, the split
    /// replaces `cache_creation_input_tokens`.
    struct CacheWriteSplit: Decodable {
        let fiveMinutes: HistoryJSON.Count?
        let oneHour: HistoryJSON.Count?
        let isPresent: Bool

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            fiveMinutes = container.lenient(.fiveMinutes)
            oneHour = container.lenient(.oneHour)
            isPresent = container.contains(.fiveMinutes) || container.contains(.oneHour)
        }

        private enum Keys: String, CodingKey {
            case fiveMinutes = "ephemeral_5m_input_tokens"
            case oneHour = "ephemeral_1h_input_tokens"
        }
    }

    let isAssistant: Bool
    let timestamp: HistoryJSON.Timestamp?
    /// The request that produced the message: `requestId`, then `request_id`. Copies of a
    /// response share it. The session ID is never used: a resumed session copies a response
    /// under a new session ID, and API message IDs are unique on their own.
    let requestID: String?
    let message: Message?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        isAssistant = (container.lenient(.type) as String?) == "assistant"
        timestamp = container.lenient(.timestamp)
        let requestIDs: [HistoryJSON.Text?] = [
            container.lenient(.requestID), container.lenient(.requestIDSnakeCase),
        ]
        requestID = requestIDs.lazy.compactMap { $0?.value }.first
        message = container.lenient(.message)
    }

    private enum Keys: String, CodingKey {
        case type, timestamp, message
        case requestID = "requestId"
        case requestIDSnakeCase = "request_id"
    }
}
