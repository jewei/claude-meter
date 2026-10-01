import ClaudeMeterCore
import CoreFoundation
import Foundation

struct TokenEvent: Equatable, Sendable {
    let date: Date
    let count: Int64
}

/// Retains counters and record identities only. Prompts and responses are discarded.
struct TokenLogParser: Sendable {
    let provider: ProviderID
    var events: [String: TokenEvent] = [:]
    var codex = CodexTokenLog()
    var isPartial = false
    var hasRecords = false

    mutating func append(_ line: Data, identity: String) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            isPartial = true
            return
        }
        switch provider {
        case .claude: appendClaude(object, identity: identity)
        case .codex: codex.append(object)
        case .grok: appendGrok(object, identity: identity)
        case .cursor: break
        }
    }

    private mutating func appendClaude(_ object: [String: Any], identity: String) {
        guard object["type"] as? String == "assistant",
            let message = object["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
        else { return }
        guard let date = TokenJSON.date(object["timestamp"]),
            let input = TokenJSON.count(usage["input_tokens"]),
            let output = TokenJSON.count(usage["output_tokens"]),
            let read = TokenJSON.count(usage["cache_read_input_tokens"], defaultZero: true)
        else {
            isPartial = true
            return
        }
        let write: Int64?
        if let split = usage["cache_creation"] as? [String: Any],
            split["ephemeral_5m_input_tokens"] != nil || split["ephemeral_1h_input_tokens"] != nil
        {
            write = TokenJSON.sum([
                TokenJSON.count(split["ephemeral_5m_input_tokens"], defaultZero: true),
                TokenJSON.count(split["ephemeral_1h_input_tokens"], defaultZero: true),
            ])
        } else {
            write = TokenJSON.count(usage["cache_creation_input_tokens"], defaultZero: true)
        }
        guard let count = TokenJSON.sum([input, output, read, write]) else {
            isPartial = true
            return
        }
        let key: String
        if let messageID = TokenJSON.string(message["id"]) {
            let request =
                TokenJSON.string(object["requestId"])
                ?? TokenJSON.string(object["request_id"])
                ?? TokenJSON.string(object["sessionId"]) ?? ""
            key = "claude:\(request):\(messageID)"
        } else {
            key = identity
            isPartial = true
        }
        // Streaming updates carry cumulative usage for one response. The final
        // complete usage row replaces the earlier row, including its output count.
        events[key] = TokenEvent(date: date, count: count)
        hasRecords = true
    }

    private mutating func appendGrok(_ object: [String: Any], identity: String) {
        let params = object["params"] as? [String: Any]
        guard let update = (params?["update"] ?? object["update"]) as? [String: Any],
            update["sessionUpdate"] as? String == "turn_completed",
            let usage = update["usage"] as? [String: Any],
            let models = usage["modelUsage"] as? [String: Any]
        else { return }
        let meta = (params?["_meta"] ?? object["_meta"]) as? [String: Any]
        let date =
            TokenJSON.milliseconds(meta?["agentTimestampMs"])
            ?? TokenJSON.date(object["timestamp"])
        guard let date else {
            isPartial = true
            return
        }
        let eventID = TokenJSON.string(meta?["eventId"])
        if eventID == nil { isPartial = true }
        for (model, raw) in models {
            guard let values = raw as? [String: Any],
                let count = TokenJSON.sum([
                    TokenJSON.count(values["inputTokens"]),
                    TokenJSON.count(values["outputTokens"], defaultZero: true),
                ])
            else {
                isPartial = true
                continue
            }
            // Cache tokens belong to input; reasoning belongs to output.
            let key = "grok:\(eventID ?? identity):\(model)"
            events[key] = TokenEvent(date: date, count: count)
            hasRecords = true
        }
    }
}

enum TokenJSON {
    static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty, string.utf8.count <= 512 else {
            return nil
        }
        return string
    }

    static func count(_ value: Any?, defaultZero: Bool = false) -> Int64? {
        guard let value, !(value is NSNull) else { return defaultZero ? 0 : nil }
        if let string = value as? String {
            guard let count = Int64(string), count >= 0 else { return nil }
            return count
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let count = Int64(number.stringValue), count >= 0
        else { return nil }
        return count
    }

    static func sum(_ values: [Int64?]) -> Int64? {
        var result: Int64 = 0
        for value in values {
            guard let value, value >= 0 else { return nil }
            let sum = result.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            result = sum.partialValue
        }
        return result
    }

    static func date(_ value: Any?) -> Date? {
        if let string = value as? String { return parseEpochOrISODate(string) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return boundedProviderDate(timeIntervalSince1970: number.doubleValue)
    }

    static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return boundedProviderDate(timeIntervalSince1970: number.doubleValue / 1000)
    }
}

struct TokenDayAccumulator {
    let now: Date
    let calendar: Calendar
    let start: Date
    var daily: [Date: Int64] = [:]
    var isPartial = false

    init(now: Date, calendar: Calendar) throws {
        guard let interval = TokenUsagePeriod.lastSevenDays.interval(asOf: now, calendar: calendar)
        else { throw TokenHistoryError.invalidDate }
        self.now = now
        self.calendar = calendar
        self.start = interval.start
    }

    mutating func add(_ event: TokenEvent) {
        guard event.date >= start else { return }
        guard event.date <= now else {
            isPartial = true
            return
        }
        let day = calendar.startOfDay(for: event.date)
        guard let total = TokenJSON.sum([daily[day, default: 0], event.count]) else {
            isPartial = true
            return
        }
        daily[day] = total
    }

    func snapshot(provider: ProviderID, hasRecords: Bool) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            provider: provider, daily: daily, periodStart: start, observedAt: now,
            timeZoneID: calendar.timeZone.identifier, hasRecords: hasRecords, isPartial: isPartial)
    }
}

enum TokenHistoryError: Error, LocalizedError, Equatable {
    case invalidDate
    case invalidCSV
    case signInChanged

    var errorDescription: String? {
        switch self {
        case .invalidDate: "The token history date is invalid."
        case .invalidCSV: "Cursor returned an invalid token history export."
        case .signInChanged: "Cursor sign-in changed during the token history check."
        }
    }
}
