import Foundation

/// Reads usage data from ~/.claude/stats-cache.json, supplemented by real-time
/// JSONL counts passed in via `supplementalCounts`.
///
/// stats-cache.json is updated infrequently (when Claude Code computes stats),
/// so recent days are covered by `supplementalCounts` from JournalReader instead.
public struct StatsCacheReader: Sendable {

    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/stats-cache.json")
    }

    public let path: URL

    public init(path: URL? = nil) {
        self.path = path ?? StatsCacheReader.defaultPath
    }

    /// - Parameters:
    ///   - supplementalCounts: Per-day message counts from JournalReader, keyed by
    ///     local date string "YYYY-MM-DD". These take priority over stats-cache counts
    ///     for the same day because they're more up-to-date.
    public func read(
        dailyMessageLimit: Int? = nil,
        weeklyMessageLimit: Int? = nil,
        supplementalCounts: [String: Int] = [:],
        now: Date = Date()
    ) throws -> ClaudeUsageSnapshot {
        // Load stats-cache if available; gracefully degrade if missing
        var cacheActivity: [String: Int] = [:]
        var cacheModelTokens: [String: [String: Int]] = [:]

        if FileManager.default.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: path),
           let cache = try? JSONDecoder().decode(StatsCacheFile.self, from: data)
        {
            for entry in cache.dailyActivity {
                cacheActivity[entry.date] = entry.messageCount
            }
            for entry in cache.dailyModelTokens {
                cacheModelTokens[entry.date] = entry.tokensByModel
            }
        } else if supplementalCounts.isEmpty {
            // No data at all
            throw StatsCacheError.fileNotFound(path.path)
        }

        return buildSnapshot(
            cacheActivity: cacheActivity,
            cacheModelTokens: cacheModelTokens,
            supplementalCounts: supplementalCounts,
            dailyMessageLimit: dailyMessageLimit,
            weeklyMessageLimit: weeklyMessageLimit,
            now: now
        )
    }

    private func buildSnapshot(
        cacheActivity: [String: Int],
        cacheModelTokens: [String: [String: Int]],
        supplementalCounts: [String: Int],
        dailyMessageLimit: Int?,
        weeklyMessageLimit: Int?,
        now: Date
    ) -> ClaudeUsageSnapshot {
        let cal = Calendar.current
        let todayStr = Self.dayString(from: now)

        // For each day: prefer journal (supplemental) counts, fall back to stats-cache
        func count(for day: String) -> Int {
            if let n = supplementalCounts[day], n > 0 { return n }
            return cacheActivity[day] ?? 0
        }

        let todayMessages = count(for: todayStr)

        let weekStartDate = cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: now)!)
        var weekMessages = 0
        var cursor = weekStartDate
        while cursor <= now {
            let dayStr = Self.dayString(from: cursor)
            weekMessages += count(for: dayStr)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
        }

        // Today's model token breakdown from stats-cache (journal doesn't track this)
        let tokensByModel = cacheModelTokens[todayStr] ?? [:]
        let modelUsages: [ModelUsage] = tokensByModel
            .map { ModelUsage(name: $0.key, inputTokens: $0.value) }
            .sorted { ($0.inputTokens ?? 0) > ($1.inputTokens ?? 0) }
        let primaryModel = modelUsages.first?.name

        // Percentages only if plan limits are configured
        let todayPct: Double? = dailyMessageLimit.flatMap { lim in
            guard lim > 0 else { return nil }
            return Double(todayMessages) / Double(lim) * 100
        }
        let weekPct: Double? = weeklyMessageLimit.flatMap { lim in
            guard lim > 0 else { return nil }
            return Double(weekMessages) / Double(lim) * 100
        }

        let tomorrowMidnight = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!)

        let todayWindow = LimitWindow(
            percentUsed: todayPct,
            resetsAt: tomorrowMidnight,
            rawValueText: "\(todayMessages) msgs"
        )
        let weekWindow = LimitWindow(
            percentUsed: weekPct,
            resetsAt: tomorrowMidnight,
            rawValueText: "\(weekMessages) msgs"
        )

        let thresholds = UsageThresholds.default
        let severity = UsageSeverity.highest(
            thresholds.severity(for: todayPct),
            thresholds.severity(for: weekPct)
        )

        return ClaudeUsageSnapshot(
            parserVersion: "stats-cache-1.0",
            createdAt: now,
            lastSuccessfulPollAt: now,
            source: SourceInfo(cliPath: path.path, command: "stats-cache+journal"),
            session: SessionInfo(activeModel: primaryModel),
            limits: LimitInfo(currentSession: todayWindow, currentWeekAllModels: weekWindow),
            models: modelUsages,
            state: SnapshotState(status: .ok, severity: severity)
        )
    }

    // MARK: - Date helpers

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dayString(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func parseDay(_ string: String) -> Date? {
        dayFormatter.date(from: string)
    }
}

// MARK: - Errors

public enum StatsCacheError: Error, LocalizedError, CustomStringConvertible {
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "Stats cache not found at \(p)"
        }
    }

    public var description: String { errorDescription ?? "StatsCacheError" }
}

// MARK: - Private Codable types for stats-cache.json

private struct StatsCacheFile: Codable {
    let dailyActivity: [DailyActivity]
    let dailyModelTokens: [DailyModelTokens]
}

private struct DailyActivity: Codable {
    let date: String
    let messageCount: Int
    let sessionCount: Int
    let toolCallCount: Int
}

private struct DailyModelTokens: Codable {
    let date: String
    let tokensByModel: [String: Int]
}
