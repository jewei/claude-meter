import AppKit
import ClaudeMeterCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppSettings.cursorSourceEnabledKey) private var cursorSourceEnabled = false
    @State private var now = Date()

    private var usageThresholds: UsageThresholds {
        AppState.currentThresholds()
    }

    private var needsOnboarding: Bool {
        !hasCompletedOnboarding
    }

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if appState.updateAvailable {
                updateAvailableNotice
            }
            if let status = appState.serviceStatus, status.level.isIncident {
                serviceStatusNotice(status)
            }
            mainContent
            footerBar
        }
        .background(Color.pfPopover)
        .onReceive(ticker) { now = $0 }
        .onAppear {
            skipOnboardingForExistingUsers()
            if needsOnboarding {
                appState.setActive(false)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 9) {
            RaisedTile(fill: .pfEnergyFull, size: 30, radius: 9) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("Claude Meter")
                .font(PFont.display(18, .semibold))
                .foregroundStyle(Color.pfInk)
            Spacer(minLength: 6)
            if !needsOnboarding {
                Text(updatedText)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                    .monospacedDigit()
                HeaderRefreshButton(
                    isLoading: appState.isLoading,
                    isEnabled: appState.isActive && appState.hasEnabledDataSource
                ) {
                    appState.refreshNow()
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Main content

    private var hasCursor: Bool {
        cursorSourceEnabled && appState.cursorUsage != nil
    }

    private var hasAnyData: Bool {
        appState.snapshot != nil || hasCursor
    }

    @ViewBuilder
    private var mainContent: some View {
        if needsOnboarding {
            onboardingContent
        } else if !appState.isActive {
            if hasAnyData { dataState } else { inactiveState }
        } else if !appState.hasEnabledDataSource {
            noSourcesState
        } else if !hasAnyData && appState.isLoading {
            loadingState
        } else if hasAnyData {
            dataState
        } else if appState.lastError != nil {
            errorState
        } else if cursorSourceEnabled && appState.cursorError != nil {
            cursorErrorState
        } else {
            setupState
        }
    }

    // MARK: - Data state

    @ViewBuilder
    private var dataState: some View {
        VStack(spacing: 12) {
            if let snap = appState.snapshot {
                claudeNotices(snap)
                let models = accountModels(snap)
                HeroView(
                    summary: HeroSummary.make(
                        models: models, thresholds: usageThresholds, now: now))
                accountsSection(models)
                if let extra = snap.limits.extraUsage, extra.hasSpend {
                    extraUsageCard(extra)
                }
                if !snap.models.isEmpty {
                    costCard(snap.models)
                }
            }
            if hasCursor, let cursor = appState.cursorUsage {
                cursorNotices()
                cursorCard(cursor)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func claudeNotices(_ snap: ClaudeUsageSnapshot) -> some View {
        if let apiWarning = appState.primarySourceWarning {
            noticeBanner(apiWarning, systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        } else if appState.lastError != nil {
            noticeBanner(pollErrorText, systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        }
        if appState.isStale {
            noticeBanner("Data may be stale", systemImage: "clock.fill", tint: .pfInkMuted)
        }
    }

    @ViewBuilder
    private func cursorNotices() -> some View {
        if appState.cursorError != nil {
            noticeBanner(
                appState.cursorError ?? "Cursor refresh failed — showing last known data",
                systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        } else if appState.cursorIsStale {
            noticeBanner("Cursor data may be outdated", systemImage: "clock.fill", tint: .pfInkMuted)
        }
    }

    // MARK: - Accounts

    private func accountsSection(_ models: [AccountCardModel]) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("ACCOUNTS")
                    .font(PFont.body(11, .heavy))
                    .tracking(0.9)
                    .foregroundStyle(Color.pfSectionLabel)
                Spacer()
                RingLegend()
            }
            .padding(.horizontal, 2)
            ForEach(models) { model in
                AccountRingCard(model: model, now: now, thresholds: usageThresholds)
            }
        }
    }

    /// Builds the unified per-account list: `snapshot.accounts` when present
    /// (active first), else a single card synthesized from the top-level snapshot.
    /// Plan/email/Opus come from OAuth and exist only for the active account.
    private func accountModels(_ snap: ClaudeUsageSnapshot) -> [AccountCardModel] {
        if let accounts = snap.accounts, !accounts.isEmpty {
            let sorted = accounts.sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            return sorted.map { acc in
                AccountCardModel(
                    id: acc.id,
                    label: AppGroupConfig.accountName(forKey: acc.id) ?? friendlyName(acc.label),
                    plan: AppGroupConfig.accountPlan(forKey: acc.id)
                        ?? (acc.isActive ? snap.account?.plan : acc.account?.plan),
                    subtitle: acc.isActive ? snap.account?.email : acc.account?.email,
                    session: acc.limits.currentSession,
                    week: acc.limits.currentWeekAllModels,
                    opus: acc.isActive ? snap.limits.currentWeekOpus : acc.limits.currentWeekOpus
                )
            }
        }
        let singleID = snap.account?.email ?? "claude"
        return [
            AccountCardModel(
                id: singleID,
                label: AppGroupConfig.accountName(forKey: singleID) ?? "Claude",
                plan: AppGroupConfig.accountPlan(forKey: singleID) ?? snap.account?.plan,
                subtitle: snap.account?.email,
                session: snap.limits.currentSession,
                week: snap.limits.currentWeekAllModels,
                opus: snap.limits.currentWeekOpus
            )
        ]
    }

    /// "it-oneone" → "It Oneone", "default" → "Default".
    private func friendlyName(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return spaced.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Extra usage (pay-as-you-go overage)

    private func extraUsageCard(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("💳").font(.system(size: 13))
                Text("Extra usage")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                if !extra.isEnabled {
                    Text("paused")
                        .font(PFont.body(10, .bold))
                        .foregroundStyle(Color.pfInkMuted)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.pfTrack))
                }
                Spacer()
                Text(extraUsageText(extra))
                    .font(PFont.display(14, .bold))
                    .foregroundStyle(Color.pfInk)
                    .monospacedDigit()
            }
            if let pct = extra.percentUsed {
                capsuleBar(fraction: min(1, pct / 100), color: .pfEnergyFull)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func extraUsageText(_ extra: ExtraUsage) -> String {
        let symbol = extra.currency == "USD" || extra.currency == nil ? "$" : "\(extra.currency!) "
        let used = String(format: "%@%.2f", symbol, extra.usedAmount ?? 0)
        if let limit = extra.limitAmount, limit > 0 {
            return used + String(format: " / %@%.2f", symbol, limit)
        }
        return used
    }

    // MARK: - Cost breakdown (local log scan, last 7 days)

    private func costCard(_ models: [ModelUsage]) -> some View {
        let total = models.reduce(0.0) { $0 + ($1.costUsd ?? 0) }
        let rows = models.filter { ($0.costUsd ?? 0) >= 0.005 }.prefix(4)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("💸").font(.system(size: 13))
                Text("Last 7 days")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                if appState.costScanPartial {
                    Text("partial")
                        .font(PFont.body(10, .semibold))
                        .foregroundStyle(Color.pfInkMuted)
                }
                Spacer()
                Text(Self.usd(total))
                    .font(PFont.display(14, .bold))
                    .foregroundStyle(Color.pfInk)
                    .monospacedDigit()
            }
            ForEach(rows, id: \.name) { model in
                HStack {
                    Text(model.displayName)
                        .font(PFont.body(12, .semibold))
                        .foregroundStyle(Color.pfInkMuted)
                    Spacer()
                    Text(Self.usd(model.costUsd ?? 0))
                        .font(PFont.body(12, .semibold))
                        .foregroundStyle(Color.pfInkMuted)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private static func usd(_ value: Double) -> String {
        value < 0.01 && value > 0 ? "<$0.01" : String(format: "$%.2f", value)
    }

    // MARK: - Cursor card (spend-based — shows % used, fills up)

    private func cursorCard(_ usage: CursorUsage) -> some View {
        let band = EnergyBand(severity: usageThresholds.severity(for: usage.percentUsed))
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image("CursorLogo").resizable().scaledToFit().frame(width: 15, height: 15)
                Text("Cursor")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                Spacer()
                Text(usage.clampedPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(PFont.display(14, .bold))
                    .foregroundStyle(band == .full ? Color.pfInk : tint)
                    .monospacedDigit()
            }
            capsuleBar(fraction: (usage.clampedPercent ?? 0) / 100, color: tint)
            if let subtitle = cursorSubtitle(usage) {
                Text(subtitle)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func cursorSubtitle(_ usage: CursorUsage) -> String? {
        var parts: [String] = []
        if let spend = usage.spendText { parts.append("\(spend) spent") }
        if let end = usage.periodEnd, end > now {
            parts.append("Resets \(Self.cursorDateFormatter.string(from: end))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let cursorDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Simple depleting/filling capsule bar with an inner top gloss.
    private func capsuleBar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.pfTrack)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
                    .overlay(alignment: .top) {
                        Capsule().fill(Color.white.opacity(0.4))
                            .frame(height: 2).padding(.horizontal, 3).padding(.top, 2)
                    }
            }
        }
        .frame(height: 12)
    }

    // MARK: - Non-data states

    private func statusState(
        emoji: String, title: String, message: String,
        primaryTitle: String? = nil, primary: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Text(emoji).font(.system(size: 40))
            Text(title)
                .font(PFont.display(16, .semibold))
                .foregroundStyle(Color.pfInk)
            Text(message)
                .font(PFont.body(12, .semibold))
                .foregroundStyle(Color.pfInkMuted)
                .multilineTextAlignment(.center)
            if let primaryTitle, let primary {
                Button(primaryTitle, action: primary)
                    .buttonStyle(RaisedButtonStyle())
                    .fixedSize()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 22)
    }

    private var onboardingContent: some View {
        statusState(
            emoji: "🚀",
            title: "Welcome to Claude Meter",
            message: "Connect a data source to start your engines.",
            primaryTitle: "Get started →",
            primary: openSettingsAndCompleteOnboarding)
    }

    private var inactiveState: some View {
        statusState(
            emoji: "😴", title: "Paused",
            message: "Hit play below to refuel the gauge.")
    }

    private var noSourcesState: some View {
        statusState(
            emoji: "🔌", title: "No data methods on",
            message: "Turn on at least one method in Settings → Data.",
            primaryTitle: "Open Settings", primary: openSettingsAndCompleteOnboarding)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(0.9)
            Text(loadingMessage)
                .font(PFont.body(13, .semibold))
                .foregroundStyle(Color.pfInkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var loadingMessage: String {
        if AppSettings.hasClaudeSource && cursorSourceEnabled { return "Checking your tanks…" }
        if cursorSourceEnabled && !AppSettings.hasClaudeSource { return "Checking Cursor…" }
        return "Checking your tanks…"
    }

    private var setupState: some View {
        statusState(emoji: "🪫", title: "No usage yet", message: setupMessage)
    }

    private var setupMessage: String {
        if cursorSourceEnabled && !AppSettings.hasClaudeSource {
            return "Sign in to the Cursor app so Claude Meter can read your billing usage."
        }
        if AppSettings.hasClaudeSource && cursorSourceEnabled {
            return "Open Claude Code or sign in to Cursor, or connect OAuth/claude.ai in Settings."
        }
        return
            "Open Claude Code so the statusline bridge can publish usage, or connect OAuth/claude.ai in Settings."
    }

    private var cursorErrorState: some View {
        statusState(
            emoji: "⚠️", title: "Couldn't read Cursor",
            message: appState.cursorError ?? "Open Cursor and try again.",
            primaryTitle: "Open Settings", primary: openSettingsAndCompleteOnboarding)
    }

    private var errorState: some View {
        statusState(
            emoji: "⚠️", title: errorTitle, message: errorHint ?? "Check Diagnostics for details.",
            primaryTitle: shouldOfferSettings ? "Open Settings" : nil,
            primary: shouldOfferSettings ? { openSettingsAndCompleteOnboarding() } : nil)
    }

    // MARK: - Notices

    private func noticeBanner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .bold))
            Text(text).font(PFont.body(11, .semibold)).lineLimit(3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.13)))
    }

    private var updateAvailableNotice: some View {
        Button {
            appState.checkForUpdates()
        } label: {
            noticeBanner(
                "Update available — click to install", systemImage: "arrow.down.circle.fill",
                tint: .pfEnergyFull)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 15)
        .padding(.bottom, 2)
    }

    private func serviceStatusNotice(_ status: ServiceStatus) -> some View {
        let tint: Color = status.level == .critical || status.level == .major ? .pfEnergyEmpty : .pfEnergyLow
        return noticeBanner(
            "Anthropic: \(status.description)", systemImage: "exclamationmark.bubble.fill", tint: tint)
            .padding(.horizontal, 15)
            .padding(.bottom, 2)
    }

    private var pollErrorText: String {
        let err = appState.lastError ?? ""
        if err.localizedCaseInsensitiveContains("session expired")
            || err.localizedCaseInsensitiveContains("session key")
        {
            return err
        }
        if err.contains("decode") || err.contains("data couldn't be read") {
            return "Refresh failed — could not parse usage data"
        }
        return "Refresh failed — showing last known data"
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 9) {
            if needsOnboarding {
                Spacer()
                squareButton("gearshape.fill", help: "Settings") {
                    openSettingsAndCompleteOnboarding()
                }
            } else {
                Button {
                    openSettingsAndCompleteOnboarding()
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(RaisedButtonStyle())

                squareButton(
                    appState.isActive ? "pause.fill" : "play.fill",
                    help: appState.isActive ? "Pause fetching" : "Resume fetching",
                    tint: appState.isActive ? .pfInkMuted : .pfEnergyFull
                ) {
                    appState.setActive(!appState.isActive)
                }
                squareButton("gearshape.fill", help: "Settings") {
                    openSettingsAndCompleteOnboarding()
                }
                squareButton("power", help: "Quit Claude Meter") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private func squareButton(
        _ symbol: String, help: String, tint: Color = .pfInkMuted, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .chunkyCard(radius: 12)
        .help(help)
    }

    /// Round refresh button in the header; spins while loading.
    private struct HeaderRefreshButton: View {
        let isLoading: Bool
        let isEnabled: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Group {
                    if isLoading {
                        TimelineView(.animation) { context in
                            icon.rotationEffect(.degrees(Self.angle(at: context.date)))
                        }
                    } else {
                        icon
                    }
                }
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.pfCard))
                .overlay(Circle().strokeBorder(Color.pfPopoverBorder, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(isLoading || !isEnabled)
        }

        private var icon: some View {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.pfInkMuted)
        }

        private static func angle(at date: Date) -> Double {
            date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
        }
    }

    private var updatedText: String {
        let claudeAt = appState.snapshot?.lastSuccessfulPollAt ?? appState.lastPolledAt
        let cursorAt = appState.cursorLastPolledAt
        guard let polledAt = [claudeAt, cursorAt].compactMap({ $0 }).max() else {
            return "Not yet polled"
        }
        let elapsed = Int(now.timeIntervalSince(polledAt))
        if elapsed < 5 { return "Just updated" }
        if elapsed < 60 { return "Updated \(elapsed)s ago" }
        let mins = elapsed / 60
        return "Updated \(mins)m ago"
    }

    // MARK: - Onboarding helpers

    private func openSettingsAndCompleteOnboarding() {
        hasCompletedOnboarding = true
        openSettings()
    }

    private func skipOnboardingForExistingUsers() {
        guard !hasCompletedOnboarding else { return }
        if appState.snapshot != nil
            || ClaudeAIKeychain.load() != nil
            || OAuthKeychain.load() != nil
            || OAuthKeychain.loadManual() != nil
            || CursorTokenStore.isStateDBPresent()
            || Self.claudeMeterDirectoryExists
        {
            hasCompletedOnboarding = true
        }
    }

    private static var claudeMeterDirectoryExists: Bool {
        FileManager.default.fileExists(
            atPath: StatuslineBridge.statuslineFilePath.deletingLastPathComponent().path,
            isDirectory: nil
        )
    }

    // MARK: - Error helpers

    private var errorTitle: String {
        let err = appState.lastError ?? ""
        if err.localizedCaseInsensitiveContains("session expired")
            || err.localizedCaseInsensitiveContains("session key")
        {
            return "Session expired"
        }
        if err.contains("decode") || err.contains("data couldn't be read") {
            return "Could not parse usage data"
        }
        return "Could not read usage stats"
    }

    private var errorHint: String? {
        let err = appState.lastError ?? ""
        if err.localizedCaseInsensitiveContains("session expired")
            || err.localizedCaseInsensitiveContains("session key")
        {
            return "Update your session key and org ID in Settings → Data."
        }
        if err.contains("decode") {
            return "Check Diagnostics for details."
        }
        return nil
    }

    private var shouldOfferSettings: Bool {
        let err = appState.lastError ?? ""
        return err.localizedCaseInsensitiveContains("session")
            || err.localizedCaseInsensitiveContains("session key")
    }
}

// MARK: - Preview helpers

extension AppState {
    static var preview: AppState {
        let snap = ClaudeUsageSnapshot(
            parserVersion: "preview-1.0",
            createdAt: Date(),
            lastSuccessfulPollAt: Date(),
            source: SourceInfo(
                cliPath: "/Users/jewei/.claude/stats-cache.json", command: "stats-cache"),
            account: AccountInfo(email: "you@oneone.com", plan: "Max"),
            session: SessionInfo(activeModel: "claude-sonnet-4-6"),
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: 22,
                    resetsAt: Date().addingTimeInterval(3 * 3600 + 12 * 60),
                    rawValueText: "245 msgs"
                ),
                currentWeekAllModels: LimitWindow(
                    percentUsed: 36,
                    resetsAt: Calendar.current.startOfDay(for: Date().addingTimeInterval(3 * 86400)),
                    rawValueText: "1482 msgs"
                )
            ),
            state: SnapshotState(status: .ok, severity: .normal)
        )
        let store = SnapshotStore(directory: FileManager.default.temporaryDirectory)
        try? store.writeLatest(snap)
        let pipeline = CachedSnapshotPipeline(store: store)
        return AppState(pipeline: pipeline, initialSnapshot: snap)
    }

    /// Three-account sample mirroring the design mock (Work / Personal / buildbot).
    /// Percentages are stored as % *used*; the UI shows the inverse as energy left.
    static var previewMulti: AppState {
        func win(used: Double, hoursToReset: Double) -> LimitWindow {
            LimitWindow(percentUsed: used, resetsAt: Date().addingTimeInterval(hoursToReset * 3600))
        }
        let work = AccountUsage(
            id: "it-oneone", label: "it-oneone",
            account: AccountInfo(email: "you@oneone.com", plan: "Max"),
            limits: LimitInfo(
                currentSession: win(used: 18, hoursToReset: 3.2),
                currentWeekAllModels: win(used: 30, hoursToReset: 72),
                currentWeekOpus: win(used: 42, hoursToReset: 72)),
            severity: .normal, isActive: true)
        let personal = AccountUsage(
            id: "personal", label: "personal",
            account: AccountInfo(plan: "Pro"),
            limits: LimitInfo(
                currentSession: win(used: 84, hoursToReset: 1.8),
                currentWeekAllModels: win(used: 24, hoursToReset: 96)),
            severity: .warning, isActive: false)
        let buildbot = AccountUsage(
            id: "buildbot", label: "buildbot",
            account: AccountInfo(plan: "Free"),
            limits: LimitInfo(
                currentSession: win(used: 97, hoursToReset: 1.1),
                currentWeekAllModels: win(used: 86, hoursToReset: 120)),
            severity: .critical, isActive: false)
        let snap = ClaudeUsageSnapshot(
            parserVersion: "preview-multi",
            createdAt: Date(), lastSuccessfulPollAt: Date(),
            source: SourceInfo(cliPath: "statusline", command: "statusline"),
            account: AccountInfo(email: "you@oneone.com", plan: "Max"),
            limits: work.limits,
            state: SnapshotState(status: .ok, severity: .normal),
            accounts: [work, personal, buildbot])
        let store = SnapshotStore(directory: FileManager.default.temporaryDirectory)
        try? store.writeLatest(snap)
        return AppState(pipeline: CachedSnapshotPipeline(store: store), initialSnapshot: snap)
    }
}

#Preview("Single account") {
    PopoverView()
        .environmentObject(AppState.preview)
        .frame(width: 360)
}

#Preview("Multi-account") {
    PopoverView()
        .environmentObject(AppState.previewMulti)
        .frame(width: 360)
}
