import Foundation
import MeterPlatform

/// The fields of one Codex rollout line that history reads. Message content and every other
/// field are skipped, so no prompt or response text is kept.
struct CodexLogLine: Decodable {
    /// The `payload` object. One type serves every line type; absent fields are nil.
    struct Payload: Decodable {
        var type: String?
        var id: String?
        var turnID: String?
        var responseID: String?
        var timestamp: HistoryJSON.Timestamp?
        /// Parent fields that are present and not null, in the order Codex has used them.
        var parents: [HistoryJSON.Text] = []
        var source: Source?
        var historyStartOrdinal: HistoryJSON.Count?
        var info: Info?
        /// The model of a `turn_context` line, such as `gpt-6-astra`.
        var model: String?

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            type = container.lenient(.type)
            id = Self.text(container, .id, .sessionID)
            turnID = Self.text(container, .turnID, .turnIDCamelCase)
            responseID = Self.text(container, .responseID, .requestID)
            timestamp = container.lenient(.timestamp)
            parents = [
                .forkedFrom, .forkedFromCamelCase, .parentSession, .parentSessionCamelCase,
                .parentThread,
            ].compactMap { container.lenient($0) }
            source = container.lenient(.source)
            historyStartOrdinal = container.lenient(.historyStartOrdinal)
            info = container.lenient(.info)
            model = Self.text(container, .model)
        }

        /// The first key that holds a usable identifier.
        private static func text(
            _ container: KeyedDecodingContainer<Keys>, _ keys: Keys...
        ) -> String? {
            keys.lazy.compactMap { (container.lenient($0) as HistoryJSON.Text?)?.value }.first
        }

        private enum Keys: String, CodingKey {
            case type, id, timestamp, source, info, model
            case sessionID = "session_id"
            case turnID = "turn_id"
            case turnIDCamelCase = "turnId"
            case responseID = "response_id"
            case requestID = "request_id"
            case forkedFrom = "forked_from_id"
            case forkedFromCamelCase = "forkedFromId"
            case parentSession = "parent_session_id"
            case parentSessionCamelCase = "parentSessionId"
            case parentThread = "parent_thread_id"
            case historyStartOrdinal = "subagent_history_start_ordinal"
        }
    }

    /// `payload.source`: text such as `cli`, or an object such as `{"subagent":"review"}` or
    /// `{"subagent":{"thread_spawn":{"parent_thread_id":…}}}`. Only a spawned thread names
    /// its parent.
    struct Source: Decodable {
        let parentID: String?

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Keys.self) else {
                parentID = nil
                return
            }
            let subagent = try? container.nestedContainer(keyedBy: Keys.self, forKey: .subagent)
            let spawn = try? subagent?.nestedContainer(keyedBy: Keys.self, forKey: .threadSpawn)
            parentID = (spawn?.lenient(.parentThread) as HistoryJSON.Text?)?.value
        }

        private enum Keys: String, CodingKey {
            case subagent
            case threadSpawn = "thread_spawn"
            case parentThread = "parent_thread_id"
        }
    }

    /// `token_count` info: cumulative and last usage, and the response they belong to.
    struct Info: Decodable {
        let total: Usage?
        let last: Usage?
        let responseID: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            total = container.lenient(.total)
            last = container.lenient(.last)
            let ids: [HistoryJSON.Text?] = [
                container.lenient(.responseID), container.lenient(.requestID),
            ]
            responseID = ids.lazy.compactMap { $0?.value }.first
        }

        private enum Keys: String, CodingKey {
            case total = "total_token_usage"
            case last = "last_token_usage"
            case responseID = "response_id"
            case requestID = "request_id"
        }
    }

    /// A usage object. Decoding never fails: `counts` is nil when the value is not an object
    /// with valid `input_tokens` and `output_tokens`. `cache` is nil when a cache count is
    /// invalid; absent cache counts are zero.
    struct Usage: Decodable {
        let counts: CodexTokenCounts?
        let cache: CodexCacheParts?

        init(from decoder: any Decoder) {
            let container = try? decoder.container(keyedBy: Keys.self)
            let input: HistoryJSON.Count? = container?.lenient(.input)
            let output: HistoryJSON.Count? = container?.lenient(.output)
            if let input = input?.value, let output = output?.value,
                TokenRecord.sum([input, output]) != nil
            {
                counts = CodexTokenCounts(input: input, output: output)
            } else {
                counts = nil
            }
            if let cached = HistoryJSON.Count.orZero(container?.lenient(.cachedInput)),
                let write = HistoryJSON.Count.orZero(container?.lenient(.cacheWrite))
            {
                cache = CodexCacheParts(cachedInput: cached, cacheWrite: write)
            } else {
                cache = nil
            }
        }

        private enum Keys: String, CodingKey {
            case input = "input_tokens"
            case output = "output_tokens"
            case cachedInput = "cached_input_tokens"
            case cacheWrite = "cache_write_input_tokens"
        }
    }

    let type: String?
    let timestamp: HistoryJSON.Timestamp?
    let ordinal: HistoryJSON.Count?
    let payload: Payload

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        type = container.lenient(.type)
        timestamp = container.lenient(.timestamp)
        ordinal = container.lenient(.ordinal)
        payload = container.lenient(.payload) ?? Payload()
    }

    private enum Keys: String, CodingKey {
        case type, timestamp, ordinal, payload
    }
}
