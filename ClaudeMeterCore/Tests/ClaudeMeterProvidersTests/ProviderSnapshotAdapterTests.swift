import ClaudeMeterCore
import Foundation
import Testing

@testable import ClaudeMeterProviders

struct ProviderSnapshotAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var reset: Date { now.addingTimeInterval(7200) }

    private func claude(_ accounts: [AccountUsage]? = nil) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            parserVersion: "oauth", createdAt: now, lastSuccessfulPollAt: now,
            source: SourceInfo(cliPath: "https://example.invalid", command: "usage"),
            account: AccountInfo(email: "person@example.com", plan: "Pro"),
            limits: LimitInfo(currentSession: LimitWindow(percentUsed: 25, resetsAt: reset)),
            state: SnapshotState(status: .ok, severity: .normal), accounts: accounts)
    }

    @Test("Claude maps one legacy-format account without copying source metadata")
    func claudeSingle() throws {
        let result = ClaudeSnapshotAdapter.snapshot(claude())
        let account = try #require(result.accounts.first)
        #expect(result.provider == .claude)
        #expect(result.accounts.count == 1)
        #expect(result.fetchedAt == now)
        #expect(account.id == "claude")
        #expect(account.label == "Claude")
        #expect(account.plan == "Pro")
        #expect(account.subtitle == "person@example.com")
        #expect(account.windows[0].usedPercent == 25)
        #expect(account.windows[0].resetAt == reset)
        #expect(account.windows[1].usedPercent == nil)
        #expect(account.windows[1].resetAt == nil)
        #expect(account.observedAt == now)
        #expect(!account.isStale)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("example.invalid"))
        #expect(!json.contains("parserVersion"))
    }

    @Test("Claude accounts preserve independent scopes, balances and freshness")
    func claudeMultiple() throws {
        let older = now.addingTimeInterval(-300)
        let accounts = [
            AccountUsage(
                id: "work", label: "Work", account: AccountInfo(plan: "Max"),
                limits: LimitInfo(
                    currentSession: LimitWindow(percentUsed: 35, resetsAt: reset),
                    currentWeekAllModels: LimitWindow(percentUsed: 60, resetsAt: reset),
                    currentWeekOpus: LimitWindow(percentUsed: 80, resetsAt: reset),
                    scopedWeekly: [
                        ScopedLimitWindow(
                            id: "seven_day_sonnet",
                            window: LimitWindow(percentUsed: 99, resetsAt: reset))
                    ],
                    extraUsage: ExtraUsage(
                        isEnabled: false, usedCredits: 1234, monthlyLimit: 5000,
                        decimalPlaces: 2, utilization: 30, currency: "USD")),
                lastSuccessfulPollAt: older, severity: .warning, isStale: true),
            AccountUsage(
                id: "claude", label: "Personal", limits: LimitInfo(),
                lastSuccessfulPollAt: now, severity: .unknown),
        ]
        let result = ClaudeSnapshotAdapter.snapshot(claude(accounts))
        #expect(result.accounts.map(\.id) == ["work", "claude"])
        #expect(result.accounts.count == 2)  // No duplicate top-level account.
        let work = result.accounts[0]
        #expect(work.plan == "Max")
        #expect(work.observedAt == older)
        #expect(work.isStale)
        #expect(!result.accounts[1].isStale)
        #expect(
            work.windows.map(\.title) == [
                "Session", "Weekly", "Opus Weekly", "Sonnet Weekly", "Extra usage",
            ])
        #expect(work.windows.map(\.usedPercent) == [35, 60, 80, 99, 30])
        #expect(work.windows.map(\.contributesToQuota) == [true, true, true, false, false])
        let balance = try #require(work.balances.first)
        #expect(balance.value == Decimal(string: "12.34"))
        #expect(balance.limit == 50)
        #expect(balance.unit == "USD")
        #expect(balance.displayText == "Paused")
        #expect(result.fetchedAt == now)
        #expect(ClaudeSnapshotAdapter.snapshot(claude([])).accounts.isEmpty)
    }

    @Test("Unknown Claude balance stays unknown")
    func claudeAllowances() throws {
        var source = claude()
        source.limits.extraUsage = ExtraUsage(isEnabled: true)
        let account = ClaudeSnapshotAdapter.snapshot(source).accounts[0]
        #expect(account.balances[0].value == nil)
        #expect(account.balances[0].limit == nil)
        #expect(account.balances[0].unit == nil)
        #expect(account.windows.last?.usedPercent == nil)

    }

    private func codex() -> CodexUsage {
        CodexUsage(
            primaryWindow: CodexLimitWindow(
                kind: .primary, usedPercent: 15, resetAt: reset, durationSeconds: 18_000,
                rawLabel: nil),
            secondaryWindow: CodexLimitWindow(
                kind: .secondary, usedPercent: 65, resetAt: reset, durationSeconds: 604_800,
                rawLabel: nil),
            usageCredits: CodexCredits(remaining: 12.5),
            rateLimitResets: CodexRateLimitResets(
                availableCount: 3,
                credits: [CodexRateLimitResetCredit(title: "Gift", expiresAt: reset)]),
            accountEmail: "private@example.com", plan: "prolite", authMode: .chatGPT,
            source: .appServer, updatedAt: now)
    }

    @Test("Codex keeps home IDs, credits and authoritative reset counts")
    func codexAccounts() throws {
        let source = codex()
        let accounts = ["/test/.codex", "/test/.codex-work"].map {
            source.providerAccountSnapshot(
                id: $0, label: URL(fileURLWithPath: $0).lastPathComponent)
        }
        let result = ProviderSnapshot(provider: .codex, accounts: accounts, fetchedAt: now)
        #expect(result.accounts.map(\.id) == ["/test/.codex", "/test/.codex-work"])
        #expect(accounts[1].label == ".codex-work")
        #expect(accounts[0].plan == "Pro 5X")
        #expect(accounts[0].subtitle == nil)
        #expect(accounts[0].windows.map(\.kind) == [.session, .weekly])
        #expect(accounts[0].windows.map(\.usedPercent) == [15, 65])
        #expect(accounts[0].windows.map(\.resetAt) == [reset, reset])
        #expect(accounts[0].balances[0].value == Decimal(string: "12.5"))
        #expect(accounts[0].balances[0].unit == "credits")
        #expect(accounts[0].balances[1].value == 3)
        #expect(accounts[0].balances[1].details == [BalanceDetail(title: "Gift", expiresAt: reset)])
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("private@example.com"))
        #expect(!json.contains("authMode"))
        #expect(!json.contains("appServer"))
    }

    @Test("Codex window duration wins, unlimited is not zero, missing detail stays unknown")
    func codexOptionalFacts() {
        var source = codex()
        source.primaryWindow?.durationSeconds = 604_800
        source.secondaryWindow = nil
        source.usageCredits = CodexCredits(remaining: 0, unlimited: true)
        source.rateLimitResets = CodexRateLimitResets(availableCount: 2, credits: nil)
        let result = source.providerAccountSnapshot(id: "home", label: "Work", isStale: true)
        #expect(result.windows[0].kind == .weekly)
        #expect(result.balances[0].value == nil)
        #expect(result.balances[0].displayText == "Unlimited")
        #expect(result.balances[1].value == 2)
        #expect(result.balances[1].details == nil)
        #expect(result.isStale)
    }

    @Test("Cursor uses reported percentage, not spend divided by limit")
    func cursor() {
        let source = CursorUsage(
            percentUsed: 20, autoPercentUsed: 40, apiPercentUsed: 5,
            spendUsd: 120.25, limitUsd: 100, periodEnd: reset,
            planName: "pro_plus", email: "private@example.com", capturedAt: now)
        let result = source.providerSnapshot()
        #expect(result.provider == .cursor)
        let account = result.accounts[0]
        #expect(account.id == "default")
        #expect(account.label == "Cursor")
        #expect(account.plan == "Pro+")
        #expect(account.subtitle == nil)
        #expect(account.windows.map(\.usedPercent) == [20, 40, 5])
        #expect(account.windows.map(\.resetAt) == [reset, reset, reset])
        #expect(account.windows.map(\.contributesToQuota) == [true, false, false])
        #expect(account.balances[0].value == Decimal(string: "120.25"))
        #expect(account.balances[0].limit == 100)
        #expect(account.balances[0].unit == "USD")
        let unknown = CursorUsage(capturedAt: now).providerSnapshot().accounts[0]
        #expect(unknown.windows.count == 1)
        #expect(unknown.windows[0].usedPercent == nil)
        #expect(unknown.balances.isEmpty)
    }

    @Test("Grok retains reported credit percentage, reset and exact money values")
    func grok() {
        let source = GrokUsage(
            usedPercent: 42, windowLabel: "Weekly", periodStart: now, resetsAt: reset,
            onDemandUsedCents: 1234, onDemandCapCents: 5000, prepaidBalanceCents: 678,
            accountEmail: "private@example.com", updatedAt: now)
        let result = source.providerSnapshot(isStale: true)
        #expect(result.provider == .grok)
        let account = result.accounts[0]
        #expect(account.id == "default")
        #expect(account.label == "Grok")
        #expect(account.plan == nil)  // This source does not report a plan.
        #expect(account.subtitle == nil)
        #expect(account.windows[0].usedPercent == 42)
        #expect(account.windows[0].resetAt == reset)
        #expect(account.windows[0].title == "Weekly")
        #expect(
            account.balances.map(\.value) == [Decimal(string: "12.34"), Decimal(string: "6.78")])
        #expect(account.balances[0].limit == 50)
        #expect(account.balances.allSatisfy { $0.unit == "USD" })
        #expect(account.observedAt == now)
        #expect(account.isStale)
    }

    @Test("Adapter percentages use one finite, used-percent convention")
    func percentBoundary() {
        let cursor = CursorUsage(percentUsed: 120, autoPercentUsed: -5, apiPercentUsed: .nan)
            .providerSnapshot()
        #expect(cursor.accounts[0].windows.map(\.usedPercent) == [100, 0, nil])
        #expect(cursor.accounts[0].windows[0].isOverLimit)
        var source = claude()
        source.limits.currentSession.percentUsed = .infinity
        #expect(ClaudeSnapshotAdapter.snapshot(source).accounts[0].windows[0].usedPercent == nil)
        var other = codex()
        other.primaryWindow?.usedPercent = -12
        #expect(
            other.providerAccountSnapshot(id: "home", label: "Codex").windows[0].usedPercent == 0)
    }
}
