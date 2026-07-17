import AppKit
import ClaudeMeterCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppSettings.cursorSourceEnabledKey) private var cursorSourceEnabled = false
    @AppStorage(AppSettings.codexSourceEnabledKey) private var codexSourceEnabled = false
    @AppStorage(AppSettings.grokSourceEnabledKey) private var grokSourceEnabled = false
    @AppStorage(AppGroupConfig.cardStyleKey) private var cardStyle = "rings"
    @AppStorage(AppGroupConfig.progressionModeKey) private var progressionMode = "left"
    @State private var now = Date()
    @State private var showHeatmap = false
    @State private var showTrends = false

    private var usageThresholds: UsageThresholds {
        AppState.currentThresholds()
    }

    /// `true` when the user chose to display usage instead of energy-left.
    private var usage: Bool { progressionMode == "used" }

    private var needsOnboarding: Bool {
        !hasCompletedOnboarding
    }

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if showHeatmap {
                heatmapBody
            } else if showTrends {
                trendsBody
            } else {
                if appState.updateAvailable {
                    updateAvailableNotice
                }
                if let status = appState.serviceStatus, status.level.isIncident {
                    serviceStatusNotice(status)
                }
                mainContent
            }
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
        // The popover view is retained across dismissals (MenuBarExtra `.window`),
        // so reset to the main view on close — otherwise reopening lands on the
        // heatmap and skips onboarding/error/loading branches.
        .onDisappear {
            showHeatmap = false
            showTrends = false
            // Don't keep burning disk I/O on a heatmap nobody is looking at.
            appState.cancelActivityHeatmapLoad()
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

    private var hasCodex: Bool {
        codexSourceEnabled && appState.codexUsage != nil
    }

    private var hasGrok: Bool {
        grokSourceEnabled && appState.grokUsage != nil
    }

    private var hasAnyData: Bool {
        appState.snapshot != nil || hasCursor || hasCodex || hasGrok
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
        } else if codexSourceEnabled && appState.codexError != nil {
            codexErrorState
        } else if grokSourceEnabled && appState.grokError != nil {
            grokErrorState
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
                } else {
                    activityEntryCard
                }
                trendsEntryCard
            }
            if hasCursor, let cursor = appState.cursorUsage {
                cursorNotices()
                cursorCard(cursor)
            }
            if hasCodex, let codex = appState.codexUsage {
                codexNotices()
                codexCard(codex)
            }
            if hasGrok, let grok = appState.grokUsage {
                grokNotices()
                grokCard(grok)
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
                if cardStyle != "bars" { RingLegend() }
            }
            .padding(.horizontal, 2)
            ForEach(models) { model in
                if cardStyle == "bars" {
                    AccountBarCard(
                        model: model, now: now, thresholds: usageThresholds, usage: usage)
                } else {
                    AccountRingCard(
                        model: model, now: now, thresholds: usageThresholds, usage: usage)
                }
            }
        }
    }

    /// Builds the unified per-account list: `snapshot.accounts` when present
    /// (active first), else a single card synthesized from the top-level snapshot.
    /// Plan/email/Opus come from OAuth and exist only for the active account.
    private func accountModels(_ snap: ClaudeUsageSnapshot) -> [AccountCardModel] {
        // "Live" = a Claude Code session is open right now: the snapshot came from
        // the statusline tier and isn't stale. OAuth-tier snapshots mean no open
        // CLI session, so no dot.
        let bridgeLive = snap.parserVersion.hasPrefix("statusline") && !appState.claudeIsStale
        if let accounts = snap.accounts, !accounts.isEmpty {
            let duplicates = MultiAccountOAuth.duplicateOrgAccountKeys(accounts)
            let sorted = accounts.sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            return sorted.map { acc in
                AccountCardModel(
                    id: acc.id,
                    label: AppGroupConfig.accountName(forKey: acc.id) ?? acc.label.friendlyAccountLabel,
                    plan: AppGroupConfig.accountPlan(forKey: acc.id)
                        ?? (acc.isActive ? snap.account?.plan : acc.account?.plan)
                        ?? acc.account?.plan,
                    subtitle: (acc.isActive ? snap.account?.email : acc.account?.email)
                        ?? acc.account?.email,
                    session: acc.limits.currentSession,
                    week: acc.limits.currentWeekAllModels,
                    opus: acc.isActive
                        ? (snap.limits.currentWeekOpus ?? acc.limits.currentWeekOpus)
                        : acc.limits.currentWeekOpus,
                    isDuplicateLogin: duplicates.contains(acc.id),
                    isLive: acc.isActive && bridgeLive
                )
            }
        }
        // Single-account override key must match how Settings stores it (the
        // discovery account key), not the OAuth email.
        let singleID = StatuslineBridge.defaultAccountKey
        return [
            AccountCardModel(
                id: singleID,
                label: AppGroupConfig.accountName(forKey: singleID) ?? "Claude",
                plan: AppGroupConfig.accountPlan(forKey: singleID) ?? snap.account?.plan,
                subtitle: snap.account?.email,
                session: snap.limits.currentSession,
                week: snap.limits.currentWeekAllModels,
                opus: snap.limits.currentWeekOpus,
                isLive: bridgeLive
            )
        ]
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
                EnergyBar(fraction: min(1, pct / 100), color: .pfEnergyFull, height: 12)
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

    /// Opens the activity heatmap and kicks off (or refreshes) its scan.
    private func openHeatmap() {
        appState.loadActivityHeatmap()
        withAnimation(.easeInOut(duration: 0.2)) { showHeatmap = true }
    }

    /// Opens the Trends screen and loads (or refreshes) the usage series.
    private func openTrends() {
        appState.loadUsageTrends()
        withAnimation(.easeInOut(duration: 0.2)) { showTrends = true }
    }

    /// Entry into the Trends screen — usage-over-time sparklines per window.
    private var trendsEntryCard: some View {
        Button(action: openTrends) {
            HStack(spacing: 7) {
                Text("📈").font(.system(size: 13))
                Text("Trends")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                Spacer()
                Text("Usage over time")
                    .font(PFont.body(12, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.pfInkMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .chunkyCard()
        }
        .buttonStyle(.plain)
        .help("View usage over time")
    }

    /// Heatmap entry when there's no 7-day cost data (OAuth-only week, pricing
    /// miss, idle week) — so activity is still reachable whenever transcripts exist.
    private var activityEntryCard: some View {
        Button(action: openHeatmap) {
            HStack(spacing: 7) {
                Text("🗓️").font(.system(size: 13))
                Text("Activity")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                Spacer()
                Text("When you work")
                    .font(PFont.body(12, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.pfInkMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .chunkyCard()
        }
        .buttonStyle(.plain)
        .help("View activity heatmap")
    }

    private func costCard(_ models: [ModelUsage]) -> some View {
        let total = models.reduce(0.0) { $0 + ($1.costUsd ?? 0) }
        let rows = models.filter { ($0.costUsd ?? 0) >= 0.005 }.prefix(4)
        return Button(action: openHeatmap) {
            VStack(alignment: .leading, spacing: 8) {
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
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.pfInkMuted)
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
        .buttonStyle(.plain)
        .help("View activity heatmap")
    }

    private static func usd(_ value: Double) -> String {
        value < 0.01 && value > 0 ? "<$0.01" : String(format: "$%.2f", value)
    }

    // MARK: - Trends (usage over time)

    private var trendsBody: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showTrends = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Back").font(PFont.display(13, .semibold))
                    }
                    .foregroundStyle(Color.pfInk)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("📈").font(.system(size: 13))
                Text("Trends")
                    .font(PFont.display(15, .semibold))
                    .foregroundStyle(Color.pfInk)
            }
            trendsContent
        }
        .padding(.horizontal, 15)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var trendsContent: some View {
        if let trends = appState.usageTrends, !trends.isEmpty {
            VStack(spacing: 10) {
                ForEach(trends.series) { series in
                    trendCard(series)
                }
                Text(usage ? "Usage climbing through each window." : "Fuel remaining through each window.")
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }
        } else if appState.usageTrendsLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            Text("No history yet — check back in a day or two.")
                .font(PFont.body(12, .semibold))
                .foregroundStyle(Color.pfInkMuted)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        }
    }

    private func trendCard(_ series: UsageTrends.Series) -> some View {
        let band = EnergyBand(severity: usageThresholds.severity(for: series.latestUsed))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(series.title)
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                Spacer()
                if let latest = series.latestUsed {
                    Text("\(Int((usage ? latest : 100 - latest).rounded()))%")
                        .font(PFont.display(14, .bold))
                        .foregroundStyle(band.color)
                        .monospacedDigit()
                }
            }
            if series.hasTrend {
                UsageSparkline(points: series.points, usage: usage, tint: band.color)
            } else {
                Text("Building history — check back in a day or two.")
                    .font(PFont.body(12, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    // MARK: - Activity heatmap (cost card flips to this)

    private var heatmapBody: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showHeatmap = false }
                    appState.cancelActivityHeatmapLoad()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Back").font(PFont.display(13, .semibold))
                    }
                    .foregroundStyle(Color.pfInk)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("🗓️").font(.system(size: 13))
                Text("Activity")
                    .font(PFont.display(15, .semibold))
                    .foregroundStyle(Color.pfInk)
            }
            heatmapCard
        }
        .padding(.horizontal, 15)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let map = appState.activityHeatmap, !map.isEmpty {
                Text(heatmapSubtitle(map))
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                ActivityHeatmapGrid(map: map)
                heatmapLegend
            } else if appState.activityHeatmapLoading {
                heatmapPlaceholder("Scanning your activity…", loading: true)
            } else {
                heatmapPlaceholder("No activity in the last 30 days")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func heatmapPlaceholder(_ text: String, loading: Bool = false) -> some View {
        VStack(spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(PFont.body(12, .semibold))
                .foregroundStyle(Color.pfInkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private func heatmapSubtitle(_ map: ActivityHeatmap) -> String {
        var parts = ["\(map.total) messages · last 30 days"]
        if map.daysCovered > 0, map.daysCovered < 30 {
            parts = ["\(map.total) messages · \(map.daysCovered) active days"]
        }
        if map.isPartial { parts.append("partial") }
        return parts.joined(separator: " · ")
    }

    private var heatmapLegend: some View {
        HStack(spacing: 5) {
            Text("Less").font(PFont.body(10, .semibold)).foregroundStyle(Color.pfInkMuted)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ActivityHeatmapGrid.color(forLevel: level))
                    .frame(width: 11, height: 11)
            }
            Text("More").font(PFont.body(10, .semibold)).foregroundStyle(Color.pfInkMuted)
            Spacer()
        }
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
            if let planName = usage.displayPlanName {
                HStack {
                    Text("Current plan")
                        .font(PFont.body(11, .semibold))
                        .foregroundStyle(Color.pfInkMuted)
                    Spacer()
                    Text(planName)
                        .font(PFont.body(11, .bold))
                        .foregroundStyle(Color.pfInk)
                }
            }
            EnergyBar(fraction: (usage.clampedPercent ?? 0) / 100, color: tint, height: 12)
            if usage.clampedAutoPercent != nil || usage.clampedAPIPercent != nil {
                Divider().overlay(Color.pfCardBorder)
                VStack(spacing: 7) {
                    if let percent = usage.clampedAutoPercent {
                        cursorUsageRow("Auto + Composer", percent: percent)
                    }
                    if let percent = usage.clampedAPIPercent {
                        cursorUsageRow("API", percent: percent)
                    }
                }
            }
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

    private func cursorUsageRow(_ label: String, percent: Double) -> some View {
        let band = EnergyBand(severity: usageThresholds.severity(for: percent))
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        return VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(PFont.body(11, .bold))
                    .foregroundStyle(Color.pfInk)
                    .monospacedDigit()
            }
            EnergyBar(fraction: percent / 100, color: tint, height: 7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) usage")
        .accessibilityValue("\(Int(percent.rounded())) percent")
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

    // MARK: - Codex card (usage-based, local to the popover)

    @ViewBuilder
    private func codexNotices() -> some View {
        if appState.codexError != nil {
            noticeBanner(
                appState.codexError ?? "Codex refresh failed — showing last known data",
                systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        } else if appState.codexIsStale {
            noticeBanner("Codex data may be outdated", systemImage: "clock.fill", tint: .pfInkMuted)
        }
    }

    private func codexCard(_ usage: CodexUsage) -> some View {
        let primary = usage.primaryWindow
        let percentUsed = primary?.usedPercent
        let displayPercent = primary?.cardDisplayPercent
        let band = EnergyBand(severity: usageThresholds.severity(for: percentUsed))
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                Text("Codex")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                Spacer()
                Text(displayPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(PFont.display(14, .bold))
                    .foregroundStyle(band == .full ? Color.pfInk : tint)
                    .monospacedDigit()
            }
            if let planName = usage.displayPlanName {
                HStack {
                    Text("Current plan")
                        .font(PFont.body(11, .semibold))
                        .foregroundStyle(Color.pfInkMuted)
                    Spacer()
                    Text(planName)
                        .font(PFont.body(11, .bold))
                        .foregroundStyle(Color.pfInk)
                }
            }
            EnergyBar(fraction: (displayPercent ?? 0) / 100, color: tint, height: 12)
            if let resets = usage.rateLimitResets {
                Divider().overlay(Color.pfCardBorder)
                VStack(spacing: 5) {
                    codexDetailRow(
                        "Usage resets",
                        value: "\(resets.availableCount) available")
                    if let expiration = resets.nearestExpiration(after: now) {
                        codexDetailRow(
                            "Next expiry",
                            value: Self.codexResetExpiryFormatter.string(from: expiration))
                    }
                }
            }
            if let subtitle = codexSubtitle(usage) {
                Text(subtitle)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func codexDetailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(PFont.body(11, .semibold))
                .foregroundStyle(Color.pfInkMuted)
            Spacer()
            Text(value)
                .font(PFont.body(11, .bold))
                .foregroundStyle(Color.pfInk)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func codexSubtitle(_ usage: CodexUsage) -> String? {
        var parts: [String] = []
        if let weekly = usage.secondaryWindow?.cardDisplayPercent {
            parts.append("Weekly \(Int(weekly.rounded()))% used")
        }
        if let credits = usage.usageCredits {
            if credits.unlimited {
                parts.append("Unlimited credits")
            } else {
                let formatted =
                    Self.codexCreditsFormatter.string(from: NSNumber(value: credits.remaining))
                    ?? "\(credits.remaining)"
                parts.append("\(formatted) credits")
            }
        }
        if let reset = usage.primaryWindow?.resetAt, reset > now {
            parts.append("Resets \(Self.codexDateFormatter.string(from: reset))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let codexResetExpiryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let codexDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let codexCreditsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }()

    // MARK: - Grok card (usage-based, local to the popover)

    @ViewBuilder
    private func grokNotices() -> some View {
        if appState.grokError != nil {
            noticeBanner(
                appState.grokError ?? "Grok refresh failed — showing last known data",
                systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        } else if appState.grokIsStale {
            noticeBanner("Grok data may be outdated", systemImage: "clock.fill", tint: .pfInkMuted)
        }
    }

    private func grokCard(_ usage: GrokUsage) -> some View {
        let band = EnergyBand(severity: usageThresholds.severity(for: usage.usedPercent))
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "atom")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                Text("Grok")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                Spacer()
                Text("\(Int(usage.cardDisplayPercent.rounded()))%")
                    .font(PFont.display(14, .bold))
                    .foregroundStyle(band == .full ? Color.pfInk : tint)
                    .monospacedDigit()
            }
            EnergyBar(fraction: usage.cardDisplayPercent / 100, color: tint, height: 12)
            if let subtitle = grokSubtitle(usage) {
                Text(subtitle)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func grokSubtitle(_ usage: GrokUsage) -> String? {
        var parts: [String] = [usage.windowLabel]
        if usage.onDemandUsedCents > 0 {
            let used = Double(usage.onDemandUsedCents) / 100
            if usage.onDemandCapCents > 0 {
                let cap = Double(usage.onDemandCapCents) / 100
                parts.append(String(format: "On-demand $%.2f of $%.2f", used, cap))
            } else {
                parts.append(String(format: "On-demand $%.2f", used))
            }
        }
        if let reset = usage.resetsAt, reset > now {
            parts.append("Resets \(Self.grokResetText(reset))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Weekly resets are usually days away — a bare time ("1:57 PM") reads as
    /// today. Same-day resets keep the time; anything later shows the date.
    private static func grokResetText(_ reset: Date) -> String {
        Calendar.current.isDateInToday(reset)
            ? codexDateFormatter.string(from: reset)
            : cursorDateFormatter.string(from: reset)
    }

    /// Simple depleting/filling capsule bar with an inner top gloss.
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
        if AppSettings.hasClaudeSource
            && (cursorSourceEnabled || codexSourceEnabled || grokSourceEnabled)
        {
            return "Checking your tanks…"
        }
        if codexSourceEnabled && !AppSettings.hasClaudeSource && !cursorSourceEnabled {
            return "Checking Codex…"
        }
        if grokSourceEnabled && !AppSettings.hasClaudeSource && !cursorSourceEnabled
            && !codexSourceEnabled
        {
            return "Checking Grok…"
        }
        if cursorSourceEnabled && !AppSettings.hasClaudeSource { return "Checking Cursor…" }
        return "Checking your tanks…"
    }

    private var setupState: some View {
        statusState(emoji: "🪫", title: "No usage yet", message: setupMessage)
    }

    private var setupMessage: String {
        if codexSourceEnabled && !AppSettings.hasClaudeSource && !cursorSourceEnabled {
            return "Install Codex or run `codex login` so Claude Meter can read Codex usage."
        }
        if cursorSourceEnabled && !AppSettings.hasClaudeSource && !codexSourceEnabled {
            return "Sign in to the Cursor app so Claude Meter can read your billing usage."
        }
        if AppSettings.hasClaudeSource && (cursorSourceEnabled || codexSourceEnabled) {
            return "Open Claude Code, sign in to enabled sources, or connect OAuth in Settings."
        }
        return
            "Open Claude Code so the statusline bridge can publish usage, or connect OAuth in Settings."
    }

    private var cursorErrorState: some View {
        statusState(
            emoji: "⚠️", title: "Couldn't read Cursor",
            message: appState.cursorError ?? "Open Cursor and try again.",
            primaryTitle: "Open Settings", primary: openSettingsAndCompleteOnboarding)
    }

    private var codexErrorState: some View {
        statusState(
            emoji: "⚠️", title: "Couldn't read Codex",
            message: appState.codexError ?? "Install Codex or run `codex login`.",
            primaryTitle: "Open Settings", primary: openSettingsAndCompleteOnboarding)
    }

    private var grokErrorState: some View {
        statusState(
            emoji: "⚠️", title: "Couldn't read Grok",
            message: appState.grokError ?? "Install Grok Build or run `grok login`.",
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
        if isSessionExpiredError(err) {
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
                if let version = appState.snapshot?.source.cliVersion {
                    versionLink(version)
                }
                Spacer(minLength: 6)

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

    /// Claude Code version (from the statusline payload), linking to the changelog.
    /// Turns amber when a newer version is published, otherwise stays muted.
    private func versionLink(_ version: String) -> some View {
        let outdated = claudeCodeUpdateAvailable(current: version)
        return Button {
            if let url = URL(
                string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md")
            {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 4) {
                Text("Claude Code v\(version)")
                    .font(PFont.body(11, .semibold))
                // Glyph changes too, so "outdated" isn't signalled by color alone
                // (colorblind / VoiceOver users get the cue without the amber).
                Image(systemName: outdated ? "arrow.up.circle.fill" : "arrow.up.right")
                    .font(.system(size: outdated ? 9 : 8, weight: .bold))
            }
            .foregroundStyle(outdated ? Color.warningTint : Color.pfInkMuted)
        }
        .buttonStyle(.plain)
        .help(
            outdated
                ? "Update available\(appState.latestClaudeCodeVersion.map { " · v\($0)" } ?? "") — view changelog"
                : "View Claude Code changelog")
        .accessibilityLabel(
            outdated
                ? "Claude Code v\(version), update available\(appState.latestClaudeCodeVersion.map { ", latest v\($0)" } ?? "")"
                : "Claude Code v\(version)")
        .accessibilityHint("Opens the Claude Code changelog")
    }

    /// Whether the running Claude Code (`current`) is behind the latest published
    /// version. False while the latest version is still unknown.
    private func claudeCodeUpdateAvailable(current: String) -> Bool {
        guard let latest = appState.latestClaudeCodeVersion else { return false }
        return ClaudeCodeVersionCheck.isOutdated(current: current, latest: latest)
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
        let claudeAt =
            AppSettings.hasClaudeSource
            ? (appState.snapshot?.lastSuccessfulPollAt ?? appState.lastPolledAt) : nil
        let cursorAt = AppSettings.cursorSourceEnabled ? appState.cursorLastPolledAt : nil
        let codexAt = AppSettings.codexSourceEnabled ? appState.codexLastPolledAt : nil
        let grokAt = AppSettings.grokSourceEnabled ? appState.grokLastPolledAt : nil
        guard
            let polledAt = [claudeAt, cursorAt, codexAt, grokAt]
                .compactMap({ $0 }).max()
        else {
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

    private func isSessionExpiredError(_ err: String) -> Bool {
        err.localizedCaseInsensitiveContains("session expired")
            || err.localizedCaseInsensitiveContains("session key")
    }

    private var errorTitle: String {
        let err = appState.lastError ?? ""
        if isSessionExpiredError(err) {
            return "Session expired"
        }
        if err.contains("decode") || err.contains("data couldn't be read") {
            return "Could not parse usage data"
        }
        return "Could not read usage stats"
    }

    private var errorHint: String? {
        let err = appState.lastError ?? ""
        if isSessionExpiredError(err) {
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
