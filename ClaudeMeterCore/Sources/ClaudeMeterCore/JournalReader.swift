import Foundation

/// Reads per-session JSONL files from ~/.claude/projects to get real-time message counts.
///
/// Supplements stats-cache.json which is only updated when Claude Code computes stats.
/// Counts "assistant" type entries (each = one API response) grouped by local calendar day.
public struct JournalReader: Sendable {

    public static var defaultProjectsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    public let projectsPath: URL

    public init(projectsPath: URL? = nil) {
        self.projectsPath = projectsPath ?? JournalReader.defaultProjectsPath
    }

    /// Returns a dict of local-date-string → assistant message count for all days
    /// within `days` days ending at `now`.
    public func messageCounts(
        daysBack days: Int = 7,
        now: Date = Date()
    ) -> [String: Int] {
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: cal.date(byAdding: .day, value: -days, to: now)!)
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsPath,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var byDay: [String: Int] = [:]
        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            guard let jsonlFiles = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for jsonlFile in jsonlFiles {
                guard jsonlFile.pathExtension == "jsonl" else { continue }
                guard let attrs = try? fm.attributesOfItem(atPath: jsonlFile.path),
                      let modDate = attrs[.modificationDate] as? Date,
                      modDate >= cutoff else { continue }
                countEntries(in: jsonlFile, since: cutoff, into: &byDay)
            }
        }
        return byDay
    }

    // MARK: - Private helpers

    private func countEntries(
        in url: URL,
        since cutoff: Date,
        into counts: inout [String: Int]
    ) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap pre-filter: skip lines that can't be "assistant" entries with timestamps
            guard line.contains("\"assistant\""), line.contains("\"timestamp\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(JournalEntry.self, from: data),
                  entry.type == "assistant",
                  let tsStr = entry.timestamp,
                  let date = Self.parseTimestamp(tsStr),
                  date >= cutoff else { continue }
            let dayStr = Self.dayString(from: date)
            counts[dayStr, default: 0] += 1
        }
    }

    nonisolated(unsafe) private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        // Uses current timezone — matches how we display dates to the user
        return f
    }()

    static func parseTimestamp(_ str: String) -> Date? {
        tsFormatter.date(from: str)
    }

    static func dayString(from date: Date) -> String {
        dayFormatter.string(from: date)
    }
}

// MARK: - Private Codable

private struct JournalEntry: Codable {
    let type: String
    let timestamp: String?
}
