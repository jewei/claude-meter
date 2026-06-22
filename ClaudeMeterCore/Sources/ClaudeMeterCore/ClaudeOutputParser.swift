import Foundation

public struct ClaudeOutputParser: Sendable {
    public static let parserVersion = "0.1.0"

    private let cliPath: String
    private let command: String
    private let now: Date
    private let timeZone: TimeZone

    public init(
        cliPath: String,
        command: String = "claude status",
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        self.cliPath = cliPath
        self.command = command
        self.now = now
        self.timeZone = timeZone
    }

    // MARK: - Public entry point

    public func parse(_ rawText: String) -> ParseResult {
        let hash = simpleHash(rawText)

        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fatal("No CLI output", hash: hash)
        }

        if isUnauthenticated(rawText) {
            return fatal("Claude CLI is not authenticated — run: claude login", hash: hash)
        }

        let text = normalize(rawText)
        var warnings: [ParseWarning] = []

        let kv = parseKeyValueFields(text)

        let (sessionWindow, sessionWarn) = parseUsageBlock(header: "Current session", in: text)
        let (weekWindow, weekWarn) = parseUsageBlock(header: "Current week", in: text)
        warnings += sessionWarn + weekWarn

        guard sessionWindow.percentUsed != nil || weekWindow.percentUsed != nil else {
            return fatal("No usage-limit blocks found in CLI output", hash: hash)
        }

        let account = AccountInfo(
            loginMethod: kv["login method"],
            organization: kv["organization"],
            email: kv["email"]
        )

        let session = SessionInfo(
            id: kv["session id"],
            name: kv["session name"],
            cwd: kv["cwd"],
            activeModel: kv["model"],
            totalCostUsd: kv["total cost"].flatMap { TokenParser.parseCost($0) },
            totalApiDurationSeconds: kv["api duration"].flatMap { parseSeconds($0) },
            codeLinesAdded: kv["lines added"].flatMap { Int($0) },
            codeLinesRemoved: kv["lines removed"].flatMap { Int($0) }
        )

        let mcp: MCPStatus?
        if let raw = kv["mcp servers"] {
            mcp = parseMCPStatus(raw)
            if mcp == nil {
                warnings.append(ParseWarning(field: "mcp", message: "Could not parse MCP server counts from: \(raw)"))
            }
        } else {
            mcp = nil
        }

        let models = parseModelTable(text, warnings: &warnings)

        let severity = UsageSeverity.highest(
            UsageSeverity.from(percent: sessionWindow.percentUsed),
            UsageSeverity.from(percent: weekWindow.percentUsed)
        )

        let snapshot = ClaudeUsageSnapshot(
            parserVersion: Self.parserVersion,
            createdAt: now,
            lastSuccessfulPollAt: now,
            source: SourceInfo(cliPath: cliPath, cliVersion: kv["version"], command: command),
            account: account.isEmpty ? nil : account,
            session: session.isEmpty ? nil : session,
            limits: LimitInfo(currentSession: sessionWindow, currentWeekAllModels: weekWindow),
            models: models,
            mcp: mcp,
            state: SnapshotState(status: .ok, severity: severity)
        )

        return ParseResult(snapshot: snapshot, warnings: warnings, errors: [], rawHash: hash)
    }

    // MARK: - Text normalization

    private func normalize(_ text: String) -> String {
        let stripped = ANSIStripper.strip(text)
        let lines = stripped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line -> String in
                // Trim trailing whitespace only; preserve leading (for indented blocks)
                var s = line
                while s.last?.isWhitespace == true { s.removeLast() }
                return s
            }
        return lines.joined(separator: "\n")
    }

    // MARK: - Auth detection

    private func isUnauthenticated(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("not logged in")
            || lower.contains("authentication required")
            || lower.contains("please run claude login")
            || lower.contains("not authenticated")
    }

    // MARK: - Key-value field parsing

    /// Parses lines of the form "Key:   value" into a lowercased-key dictionary.
    private func parseKeyValueFields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        // Match "Key name:   value" where key is word chars + spaces, followed by colon
        let pattern = /^([A-Za-z][A-Za-z ]+?):\s{2,}(.+)$/
        for line in text.components(separatedBy: "\n") {
            if let m = line.firstMatch(of: pattern) {
                let key = String(m.output.1).lowercased().trimmingCharacters(in: .whitespaces)
                let value = String(m.output.2).trimmingCharacters(in: .whitespaces)
                result[key] = value
            }
        }
        return result
    }

    // MARK: - Usage block parsing

    private func parseUsageBlock(header: String, in text: String) -> (LimitWindow, [ParseWarning]) {
        var warnings: [ParseWarning] = []
        let lines = text.components(separatedBy: "\n")
        let headerLower = header.lowercased()

        guard let idx = lines.firstIndex(where: { $0.lowercased().hasPrefix(headerLower) }) else {
            warnings.append(ParseWarning(field: header, message: "Usage block '\(header)' not found in output"))
            return (LimitWindow(), warnings)
        }

        // Scan up to 6 lines after the header for percent + reset
        let blockEnd = min(idx + 7, lines.count)
        let block = lines[(idx + 1)..<blockEnd]

        var percentUsed: Double?
        var rawResetText: String?

        let percentPattern = /(\d+\.?\d*)\s*%\s*used/
        let resetPattern = /^Resets?\s+(.+)$/

        for line in block {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if percentUsed == nil, let m = trimmed.firstMatch(of: percentPattern) {
                percentUsed = Double(m.output.1)
            }

            if rawResetText == nil, let m = trimmed.firstMatch(of: resetPattern) {
                rawResetText = String(m.output.1).trimmingCharacters(in: .whitespaces)
            }
        }

        if percentUsed == nil {
            warnings.append(ParseWarning(field: header, message: "Could not parse usage percentage"))
        }

        var resetsAt: Date?
        if let raw = rawResetText {
            resetsAt = ResetTimeParser.parse(raw, now: now, fallbackTimeZone: timeZone)
            if resetsAt == nil {
                warnings.append(ParseWarning(field: header, message: "Could not parse reset time: \(raw)"))
            }
        } else {
            warnings.append(ParseWarning(field: header, message: "No reset time found in block"))
        }

        return (
            LimitWindow(percentUsed: percentUsed, resetsAt: resetsAt, rawResetText: rawResetText),
            warnings
        )
    }

    // MARK: - MCP status parsing

    private func parseMCPStatus(_ raw: String) -> MCPStatus? {
        func extract(_ pattern: Regex<(Substring, Substring)>) -> Int? {
            raw.firstMatch(of: pattern).flatMap { Int($0.output.1) }
        }

        let connected = extract(/(\d+)\s+connected/)
        let needsAuth = extract(/(\d+)\s+need\s+auth/)
        let failed = extract(/(\d+)\s+failed/)

        guard connected != nil || needsAuth != nil || failed != nil else { return nil }
        return MCPStatus(connected: connected, needsAuth: needsAuth, failed: failed, raw: raw)
    }

    // MARK: - Model table parsing (claude stats)

    /// Parses a whitespace-aligned table of model usage stats.
    /// Emits a warning (not an error) if parsing fails — stats are informational.
    private func parseModelTable(_ text: String, warnings: inout [ParseWarning]) -> [ModelUsage] {
        let lines = text.components(separatedBy: "\n")

        // Detect header line containing "Model" and "Input" / "Output"
        guard let headerIdx = lines.firstIndex(where: {
            $0.contains("Model") && ($0.contains("Input") || $0.contains("Tokens"))
        }) else {
            return []
        }

        var models: [ModelUsage] = []
        for line in lines[(headerIdx + 1)...] {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 2 else { continue }

            // First column is model name, rest are numeric values
            let name = cols[0]
            // Model names typically contain "claude" or a version pattern
            guard name.lowercased().contains("claude") || name.contains("-") else { continue }

            var usage = ModelUsage(name: name)
            if cols.count > 1 { usage.inputTokens = TokenParser.parseCount(cols[1]) }
            if cols.count > 2 { usage.outputTokens = TokenParser.parseCount(cols[2]) }
            if cols.count > 3 { usage.cacheReadTokens = TokenParser.parseCount(cols[3]) }
            if cols.count > 4 { usage.cacheWriteTokens = TokenParser.parseCount(cols[4]) }
            if cols.count > 5 { usage.costUsd = TokenParser.parseCost(cols[cols.count - 1]) }
            models.append(usage)
        }

        if models.isEmpty && text.contains("claude") {
            warnings.append(ParseWarning(field: "models", message: "Could not parse model usage table"))
        }
        return models
    }

    // MARK: - Helpers

    private func parseSeconds(_ s: String) -> Int? {
        // Accepts "4047", "4047s", "4047 seconds"
        let digits = s.filter(\.isNumber)
        return Int(digits)
    }

    private func fatal(_ message: String, hash: String) -> ParseResult {
        ParseResult(snapshot: nil, warnings: [], errors: [ParseError(message)], rawHash: hash)
    }

    private func simpleHash(_ text: String) -> String {
        var h: UInt64 = 5381
        for byte in text.utf8 {
            h = (h &<< 5) &+ h &+ UInt64(byte)
        }
        return String(format: "%016llx", h)
    }
}
