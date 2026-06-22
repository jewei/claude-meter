import Foundation

public struct ClaudeOutputParser: Sendable {
    public static let parserVersion = "0.1.0"

    private let cliPath: String
    private let command: String
    private let timeZone: TimeZone

    public init(
        cliPath: String,
        command: String = "claude status",
        timeZone: TimeZone = .current
    ) {
        self.cliPath = cliPath
        self.command = command
        self.timeZone = timeZone
    }

    // MARK: - Public entry point

    public func parse(_ rawText: String, now: Date = Date()) -> ParseResult {
        let hash = simpleHash(rawText)

        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fatal("No CLI output", hash: hash)
        }

        let text = normalize(rawText)

        if isUnauthenticated(text) {
            return fatal("Claude CLI is not authenticated — run: claude login", hash: hash)
        }

        var warnings: [ParseWarning] = []

        let kv = parseKeyValueFields(text)

        let (sessionWindow, sessionWarn) = parseUsageBlock(header: "Current session", in: text, now: now)
        let (weekWindow, weekWarn) = parseUsageBlock(header: "Current week", in: text, now: now)
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
            lastSuccessfulPollAt: nil,
            source: SourceInfo(cliPath: cliPath, cliVersion: kv["version"], command: command),
            account: account.isEmpty ? nil : account,
            session: session.isEmpty ? nil : session,
            limits: LimitInfo(currentSession: sessionWindow, currentWeekAllModels: weekWindow),
            models: models,
            mcp: mcp,
            settingSources: kv["setting sources"],
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
        let authPhrases = [
            "not logged in",
            "authentication required",
            "please run claude login",
            "not authenticated",
        ]

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()

            if lower.hasPrefix("error:") {
                if authPhrases.contains(where: { lower.contains($0) }) { return true }
                continue
            }

            // Skip key-value lines — auth-like phrases in field values are not errors
            if isKeyValueLine(trimmed) { continue }

            if authPhrases.contains(where: { lower.hasPrefix($0) }) { return true }
        }
        return false
    }

    private func isUsageSectionHeader(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("current session") || lower.hasPrefix("current week")
    }

    private func isKeyValueLine(_ line: String) -> Bool {
        line.firstMatch(of: /^[A-Za-z][A-Za-z ]+:\s+/) != nil
    }

    // MARK: - Key-value field parsing

    /// Parses lines of the form "Key: value" into a lowercased-key dictionary.
    private func parseKeyValueFields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = /^([A-Za-z][A-Za-z ]+?):\s+(.+)$/
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

    private func parseUsageBlock(header: String, in text: String, now: Date) -> (LimitWindow, [ParseWarning]) {
        var warnings: [ParseWarning] = []
        let lines = text.components(separatedBy: "\n")
        let headerLower = header.lowercased()

        guard let idx = lines.firstIndex(where: { $0.lowercased().hasPrefix(headerLower) }) else {
            warnings.append(ParseWarning(field: header, message: "Usage block '\(header)' not found in output"))
            return (LimitWindow(), warnings)
        }

        let block = collectUsageBlock(lines: lines, from: idx)

        var percentUsed: Double?
        var rawResetText: String?

        let percentPattern = /(-?\d+\.?\d*)\s*%\s*used/
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
            if !ResetTimeParser.hasTimezoneIdentifier(raw) {
                warnings.append(ParseWarning(field: header, message: "Reset timezone missing; using fallback timezone"))
            }
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

    private func collectUsageBlock(lines: [String], from idx: Int) -> ArraySlice<String> {
        var end = lines.count
        for i in (idx + 1)..<lines.count {
            let line = lines[i]
            if isUsageSectionHeader(line) {
                end = i
                break
            }
            if isKeyValueLine(line) {
                end = i
                break
            }
        }
        return lines[(idx + 1)..<end]
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

        guard let headerIdx = lines.firstIndex(where: {
            $0.contains("Model") && ($0.contains("Input") || $0.contains("Tokens"))
        }) else {
            return []
        }

        var models: [ModelUsage] = []
        for line in lines[(headerIdx + 1)...] {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 2 else { continue }

            let name = cols[0]
            guard looksLikeModelName(name) else { continue }

            var usage = ModelUsage(name: name)
            if cols.count > 1 { usage.inputTokens = TokenParser.parseCount(cols[1]) }
            if cols.count > 2 { usage.outputTokens = TokenParser.parseCount(cols[2]) }
            if cols.count > 3 { usage.cacheReadTokens = TokenParser.parseCount(cols[3]) }
            if cols.count > 4 { usage.cacheWriteTokens = TokenParser.parseCount(cols[4]) }
            if cols.count > 5 { usage.costUsd = TokenParser.parseCost(cols[cols.count - 1]) }
            models.append(usage)
        }

        if models.isEmpty {
            warnings.append(ParseWarning(field: "models", message: "Could not parse model usage table"))
        }
        return models
    }

    private func looksLikeModelName(_ name: String) -> Bool {
        name.lowercased().hasPrefix("claude")
    }

    // MARK: - Helpers

    private func parseSeconds(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let m = trimmed.firstMatch(of: /^(\d+)\s*(?:s|sec|seconds)?$/) {
            return Int(m.output.1)
        }
        if trimmed.allSatisfy(\.isNumber) {
            return Int(trimmed)
        }
        return nil
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
