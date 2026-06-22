import Testing
import Foundation
@testable import ClaudeMeterCore

// Fixed reference: 2026-06-22T06:00:00Z — 14:00 MYT (2:50pm MYT is in the future)
private let fixedNow = Date(timeIntervalSince1970: 1_782_108_000)
private let klTZ = TimeZone(identifier: "Asia/Kuala_Lumpur")!

private func makeParser() -> ClaudeOutputParser {
    ClaudeOutputParser(
        cliPath: "/opt/homebrew/bin/claude",
        command: "claude status",
        now: fixedNow,
        timeZone: klTZ
    )
}

private func fixture(_ name: String) throws -> String {
    let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")
    let path = url ?? URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).txt")
    return try String(contentsOf: path, encoding: .utf8)
}

@Suite("ClaudeOutputParser")
struct ClaudeOutputParserTests {

    // MARK: - Full status fixture

    @Test("Parses full status output")
    func fullStatus() throws {
        let text = try fixture("full_status")
        let result = makeParser().parse(text)

        #expect(result.errors.isEmpty)
        let snap = try #require(result.snapshot)

        #expect(snap.limits.currentSession.percentUsed == 25)
        #expect(snap.limits.currentWeekAllModels.percentUsed == 30)
        #expect(snap.limits.currentSession.rawResetText == "2:50pm (Asia/Kuala_Lumpur)")
        #expect(snap.limits.currentWeekAllModels.rawResetText == "Jun 27 at 3pm (Asia/Kuala_Lumpur)")
        #expect(snap.limits.currentSession.resetsAt != nil)
        #expect(snap.limits.currentWeekAllModels.resetsAt != nil)

        #expect(snap.source.cliVersion == "2.1.185")
        #expect(snap.session?.activeModel == "claude-opus-4-8")
        #expect(snap.session?.id == "d49ac283-b694-4873-853d-eeaf873aaad4")
        #expect(snap.session?.name == "Implement fraud detection score weighting")
        #expect(snap.account?.email == "jewei.mak@gmail.com")
        #expect(snap.account?.loginMethod == "Claude Pro account")

        #expect(snap.mcp?.connected == 8)
        #expect(snap.mcp?.needsAuth == 3)
        #expect(snap.mcp?.failed == 1)

        #expect(snap.state.status == .ok)
        #expect(snap.state.severity == .normal)
    }

    // MARK: - Minimal fixture

    @Test("Parses minimal output (usage blocks only)")
    func minimal() throws {
        let text = try fixture("minimal")
        let result = makeParser().parse(text)

        #expect(result.errors.isEmpty)
        let snap = try #require(result.snapshot)
        #expect(snap.limits.currentSession.percentUsed == 25)
        #expect(snap.limits.currentWeekAllModels.percentUsed == 30)
        #expect(snap.session == nil)
        #expect(snap.account == nil)
    }

    // MARK: - Missing sections

    @Test("Succeeds when weekly block is absent")
    func noWeekly() throws {
        let text = try fixture("no_weekly")
        let result = makeParser().parse(text)

        #expect(result.errors.isEmpty)
        let snap = try #require(result.snapshot)
        #expect(snap.limits.currentSession.percentUsed == 25)
        #expect(snap.limits.currentWeekAllModels.percentUsed == nil)
        #expect(result.warnings.contains { $0.field.contains("Current week") })
    }

    @Test("Succeeds when session block is absent")
    func noSession() throws {
        let text = try fixture("no_session")
        let result = makeParser().parse(text)

        #expect(result.errors.isEmpty)
        let snap = try #require(result.snapshot)
        #expect(snap.limits.currentSession.percentUsed == nil)
        #expect(snap.limits.currentWeekAllModels.percentUsed == 30)
    }

    // MARK: - Decimal and over-100 percentages

    @Test("Parses decimal percentages")
    func decimalPercent() throws {
        let text = try fixture("decimal_percent")
        let result = makeParser().parse(text)

        #expect(result.errors.isEmpty)
        let snap = try #require(result.snapshot)
        #expect(snap.limits.currentSession.percentUsed == 84.5)
        #expect(snap.limits.currentWeekAllModels.percentUsed == 30.7)
        #expect(snap.state.severity == .warning)
    }

    @Test("Parses over-100 percent and reports overLimit severity")
    func over100() throws {
        let text = try fixture("over100")
        let result = makeParser().parse(text)

        #expect(result.errors.isEmpty)
        let snap = try #require(result.snapshot)
        #expect(snap.limits.currentSession.percentUsed == 102)
        #expect(snap.limits.currentSession.isOverLimit == true)
        #expect(snap.limits.currentSession.clampedPercent == 100)
        #expect(snap.state.severity == .overLimit)
    }

    // MARK: - Reset time formats

    @Test("Parses long month reset format")
    func longMonthReset() throws {
        let text = try fixture("long_month_reset")
        let result = makeParser().parse(text)

        #expect(result.errors.isEmpty)
        let snap = try #require(result.snapshot)
        #expect(snap.limits.currentWeekAllModels.resetsAt != nil)
        let comps = Calendar.current.dateComponents(in: klTZ, from: snap.limits.currentWeekAllModels.resetsAt!)
        #expect(comps.month == 6)
        #expect(comps.day == 27)
        #expect(comps.hour == 15)
        #expect(comps.minute == 0)
    }

    @Test("Emits warning (not error) for missing timezone")
    func missingTimezone() throws {
        let text = try fixture("missing_timezone")
        let result = makeParser().parse(text)

        // Should still produce a snapshot — missing timezone is non-fatal
        #expect(result.errors.isEmpty)
        let snap = try #require(result.snapshot)
        // Parser uses fallback timezone (klTZ); reset time still parsed
        #expect(snap.limits.currentSession.percentUsed == 25)
        // Raw text preserved
        #expect(snap.limits.currentSession.rawResetText == "2:50pm")
    }

    // MARK: - ANSI stripping

    @Test("Strips ANSI escape codes before parsing")
    func ansiStripping() throws {
        let ansiText = """
        \u{1B}[1mCurrent session\u{1B}[0m
        \u{1B}[32m████████████▌\u{1B}[0m                                      25% used
        Resets 2:50pm (Asia/Kuala_Lumpur)

        \u{1B}[1mCurrent week (all models)\u{1B}[0m
        \u{1B}[32m███████████████\u{1B}[0m                                    30% used
        Resets Jun 27 at 3pm (Asia/Kuala_Lumpur)
        """

        let result = makeParser().parse(ansiText)
        #expect(result.errors.isEmpty)
        let snap = try #require(result.snapshot)
        #expect(snap.limits.currentSession.percentUsed == 25)
        #expect(snap.limits.currentWeekAllModels.percentUsed == 30)
    }

    // MARK: - Error cases

    @Test("Returns fatal error for empty output")
    func emptyOutput() throws {
        let text = try fixture("empty")
        let result = makeParser().parse(text)

        #expect(result.snapshot == nil)
        #expect(!result.errors.isEmpty)
        #expect(result.errors[0].message.contains("No CLI output"))
    }

    @Test("Returns unauthenticated error")
    func unauthenticated() throws {
        let text = try fixture("unauthenticated")
        let result = makeParser().parse(text)

        #expect(result.snapshot == nil)
        #expect(result.errors.contains { $0.message.contains("authenticated") })
    }

    @Test("Returns fatal error when no usage blocks found")
    func noUsageBlocks() {
        let text = "Version:          2.1.185\nModel:            claude-opus-4-8\n"
        let result = makeParser().parse(text)

        #expect(result.snapshot == nil)
        #expect(result.errors.contains { $0.message.contains("No usage-limit blocks") })
    }

    // MARK: - MCP parsing

    @Test("Parses MCP server counts")
    func mcpParsing() throws {
        let text = try fixture("full_status")
        let result = makeParser().parse(text)
        let snap = try #require(result.snapshot)

        #expect(snap.mcp?.connected == 8)
        #expect(snap.mcp?.needsAuth == 3)
        #expect(snap.mcp?.failed == 1)
        #expect(snap.mcp?.raw == "8 connected, 3 need auth, 1 failed · /mcp")
    }

    @Test("Handles absent MCP field without error")
    func mcpAbsent() throws {
        let text = try fixture("minimal")
        let result = makeParser().parse(text)
        let snap = try #require(result.snapshot)
        #expect(snap.mcp == nil)
    }

    // MARK: - Severity

    @Test("Severity is normal below 80%")
    func severityNormal() throws {
        let text = try fixture("minimal")  // 25% / 30%
        let snap = try #require(makeParser().parse(text).snapshot)
        #expect(snap.state.severity == .normal)
    }

    @Test("Severity is warning between 80-94%")
    func severityWarning() throws {
        let text = try fixture("decimal_percent")  // 84.5%
        let snap = try #require(makeParser().parse(text).snapshot)
        #expect(snap.state.severity == .warning)
    }

    @Test("Severity reflects highest across session and week")
    func severityHighest() throws {
        let text = """
        Current session
        ████████████▌                                      96% used
        Resets 2:50pm (Asia/Kuala_Lumpur)

        Current week (all models)
        ███████████████                                    30% used
        Resets Jun 27 at 3pm (Asia/Kuala_Lumpur)
        """
        let snap = try #require(makeParser().parse(text).snapshot)
        #expect(snap.state.severity == .critical)
    }
}

// MARK: - Token parser tests

@Suite("TokenParser")
struct TokenParserTests {
    @Test("Parses k suffix") func k() { #expect(TokenParser.parseCount("8.4k") == 8400) }
    @Test("Parses m suffix") func m() { #expect(TokenParser.parseCount("22.6m") == 22_600_000) }
    @Test("Parses b suffix") func b() { #expect(TokenParser.parseCount("1.3b") == 1_300_000_000) }
    @Test("Parses plain integer") func plain() { #expect(TokenParser.parseCount("1234") == 1234) }
    @Test("Parses cost with dollar sign") func cost() { #expect(TokenParser.parseCost("$6.89") == 6.89) }
    @Test("Parses cost without dollar sign") func costNoDollar() { #expect(TokenParser.parseCost("21.20") == 21.20) }
}

// MARK: - ANSI stripper tests

@Suite("ANSIStripper")
struct ANSIStripperTests {
    @Test("Strips color codes") func color() {
        #expect(ANSIStripper.strip("\u{1B}[32mhello\u{1B}[0m") == "hello")
    }
    @Test("Strips bold code") func bold() {
        #expect(ANSIStripper.strip("\u{1B}[1mtext\u{1B}[0m") == "text")
    }
    @Test("Strips 256-color codes") func color256() {
        #expect(ANSIStripper.strip("\u{1B}[38;5;220mtext\u{1B}[0m") == "text")
    }
    @Test("Leaves plain text untouched") func plain() {
        #expect(ANSIStripper.strip("hello world") == "hello world")
    }
    @Test("Preserves Unicode progress characters") func progressBar() {
        let bar = "████████▌░░░░░░░░"
        #expect(ANSIStripper.strip(bar) == bar)
    }
}
