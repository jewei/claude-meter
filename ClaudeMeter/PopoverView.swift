import SwiftUI
import ClaudeMeterCore
import AppKit

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

    /// Claude "clay" brand color used to tint the Claude glyph.
    private static let claudeTint = Color(hex: "D97757")

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if appState.updateAvailable {
                updateAvailableNotice
                Divider()
            }
            if let status = appState.serviceStatus, status.level.isIncident {
                serviceStatusNotice(status)
                Divider()
            }
            mainContent
            Divider()
            footerBar
        }
        .background(.regularMaterial)
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
        HStack(spacing: 8) {
            Text("Claude Meter")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            if let plan = appState.snapshot?.account?.plan {
                Text(plan)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.claudeTint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Self.claudeTint.opacity(0.15), in: Capsule())
            }
            Spacer()
            Toggle(isOn: activeBinding) { }
                .toggleStyle(.switch)
                .labelsHidden()
                .help(appState.isActive ? "Active — fetching usage data" : "Paused — not fetching usage data")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var activeBinding: Binding<Bool> {
        Binding(
            get: { appState.isActive },
            set: { appState.setActive($0) }
        )
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
            if hasAnyData {
                dataState
            } else {
                inactiveState
            }
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

    private var onboardingContent: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

            // Asset catalog image, not `applicationIconImage` (which returns the
            // generic macOS placeholder for LSUIElement apps).
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(spacing: 4) {
                HStack(spacing: 0) {
                    Text("Welcome to ")
                        .foregroundStyle(Color(hex: "a8b4c8"))
                    Text("Claude Meter")
                        .foregroundStyle(Color(hex: "f0a878"))
                }
                .font(.title3.weight(.bold))
            }

            Text("Click the settings button below to configure your data sources and get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Spacer(minLength: 8)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(hex: "f0a878"))
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }

    private var inactiveState: some View {
        VStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Paused")
                .font(.system(size: 13, weight: .medium))
            Text("Turn on the toggle above to start fetching usage data.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    private var noSourcesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "switch.2")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No data methods enabled")
                .font(.system(size: 13, weight: .medium))
            Text("Turn on at least one method in Settings → Data.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { openSettingsAndCompleteOnboarding() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().scaleEffect(0.8)
            Text(loadingMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var loadingMessage: String {
        if AppSettings.hasClaudeSource && cursorSourceEnabled { return "Checking usage…" }
        if cursorSourceEnabled && !AppSettings.hasClaudeSource { return "Checking Cursor…" }
        return "Checking Claude…"
    }

    private var setupState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No usage data yet")
                .font(.system(size: 13, weight: .medium))
            Text(setupMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    private var setupMessage: String {
        if cursorSourceEnabled && !AppSettings.hasClaudeSource {
            return "Sign in to the Cursor app so Claude Meter can read your billing usage."
        }
        if AppSettings.hasClaudeSource && cursorSourceEnabled {
            return "Open Claude Code or sign in to Cursor, or connect OAuth/claude.ai in Settings."
        }
        return "Open Claude Code so the statusline bridge can publish usage, or connect OAuth/claude.ai in Settings."
    }

    private var cursorErrorState: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.red)
            Text("Could not read Cursor usage")
                .font(.system(size: 13, weight: .medium))
            if let err = appState.cursorError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Open Settings") { openSettingsAndCompleteOnboarding() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    private var errorState: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.red)
            Text(errorTitle)
                .font(.system(size: 13, weight: .medium))
            if let hint = errorHint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if shouldOfferSettings {
                Button("Open Settings") { openSettingsAndCompleteOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var dataState: some View {
        VStack(spacing: 0) {
            if let snap = appState.snapshot {
                if let apiWarning = appState.primarySourceWarning {
                    apiDegradedNotice(apiWarning)
                    Divider()
                } else if appState.lastError != nil {
                    pollErrorNotice
                    Divider()
                }
                if appState.isStale {
                    staleNotice
                    Divider()
                }
                UsageCardView(
                    label: "Current Session",
                    window: snap.limits.currentSession,
                    now: now,
                    thresholds: usageThresholds,
                    paceKind: .session,
                    leadingIcon: "ClaudeLogo",
                    leadingIconColor: Self.claudeTint
                )
                Divider().padding(.horizontal, 14)
                UsageCardView(
                    label: "This Week",
                    window: snap.limits.currentWeekAllModels,
                    now: now,
                    thresholds: usageThresholds,
                    paceKind: .weekly,
                    leadingIcon: "ClaudeLogo",
                    leadingIconColor: Self.claudeTint
                )
                if let opus = snap.limits.currentWeekOpus {
                    Divider().padding(.horizontal, 14)
                    UsageCardView(
                        label: "This Week (Opus)",
                        window: opus,
                        now: now,
                        thresholds: usageThresholds,
                        paceKind: .weekly,
                        leadingIcon: "ClaudeLogo",
                        leadingIconColor: Self.claudeTint
                    )
                }
                if let extra = snap.limits.extraUsage, extra.hasSpend {
                    Divider().padding(.horizontal, 14)
                    extraUsageRow(extra)
                }
                if !snap.models.isEmpty {
                    Divider().padding(.horizontal, 14)
                    costBreakdown(snap.models)
                }
            }
            if hasCursor, let cursor = appState.cursorUsage {
                if appState.snapshot != nil { Divider().padding(.horizontal, 14) }
                if appState.cursorError != nil {
                    cursorPollErrorNotice
                    Divider()
                } else if appState.cursorIsStale {
                    cursorStaleNotice
                    Divider()
                }
                cursorCard(cursor)
            }
        }
    }

    // MARK: - Cost breakdown (local log scan, last 7 days)

    private func costBreakdown(_ models: [ModelUsage]) -> some View {
        // Total reflects all models; the per-row list hides sub-cent/no-cost noise
        // (e.g. synthetic helper models) to keep the breakdown legible.
        let total = models.reduce(0.0) { $0 + ($1.costUsd ?? 0) }
        let rows = models.filter { ($0.costUsd ?? 0) >= 0.005 }.prefix(4)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Last 7 days")
                    .font(.body.weight(.semibold))
                if appState.costScanPartial {
                    Text("partial")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.usd(total))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
            }
            ForEach(rows, id: \.name) { model in
                HStack {
                    Text(model.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.usd(model.costUsd ?? 0))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static func usd(_ value: Double) -> String {
        value < 0.01 && value > 0
            ? "<$0.01"
            : String(format: "$%.2f", value)
    }

    // MARK: - Extra usage (pay-as-you-go overage)

    private func extraUsageRow(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "creditcard")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Extra usage")
                    .font(.body.weight(.semibold))
                if !extra.isEnabled {
                    Text("paused")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                }
                Spacer()
                Text(extraUsageText(extra))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            if let pct = extra.percentUsed {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(0, geo.size.width * min(1, pct / 100)))
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func extraUsageText(_ extra: ExtraUsage) -> String {
        let symbol = extra.currency == "USD" || extra.currency == nil ? "$" : "\(extra.currency!) "
        let used = String(format: "%@%.2f", symbol, extra.usedAmount ?? 0)
        if let limit = extra.limitAmount, limit > 0 {
            return used + String(format: " / %@%.2f", symbol, limit)
        }
        return used
    }

    // MARK: - Cursor card

    private func cursorCard(_ usage: CursorUsage) -> some View {
        let severity = usageThresholds.severity(for: usage.percentUsed)
        let tint: Color = {
            switch severity {
            case .warning: return .orange
            case .critical, .overLimit: return .red
            default: return .accentColor
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image("CursorLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                Text("Cursor").font(.body.weight(.semibold))
                Spacer()
                Text(usage.clampedPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(severity == .normal || severity == .unknown ? Color.primary : tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(tint)
                        .frame(width: max(0, geo.size.width * ((usage.clampedPercent ?? 0) / 100)))
                }
            }
            .frame(height: 5)
            if let subtitle = cursorSubtitle(usage) {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    // MARK: - Notices

    private var updateAvailableNotice: some View {
        Button {
            appState.checkForUpdates()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                Text("Update available — click to install")
                Spacer()
            }
            .font(.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func serviceStatusNotice(_ status: ServiceStatus) -> some View {
        let color: Color = status.level == .critical || status.level == .major ? .red : .orange
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.bubble")
            Text("Anthropic: \(status.description)")
                .lineLimit(2)
            Spacer()
        }
        .font(.body)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var pollErrorNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(pollErrorText)
                .lineLimit(3)
        }
        .font(.body)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var cursorPollErrorNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(appState.cursorError ?? "Cursor refresh failed — showing last known data")
                .lineLimit(3)
        }
        .font(.body)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var cursorStaleNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text("Cursor data may be outdated")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func apiDegradedNotice(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .lineLimit(3)
        }
        .font(.body)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var pollErrorText: String {
        let err = appState.lastError ?? ""
        if err.localizedCaseInsensitiveContains("session expired")
            || err.localizedCaseInsensitiveContains("session key") {
            return err
        }
        if err.contains("decode") || err.contains("data couldn't be read") {
            return "Refresh failed — could not parse usage data"
        }
        return "Refresh failed — showing last known data"
    }

    private var staleNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text("Data may be outdated")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            if !needsOnboarding {
                Text(updatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            footerButton("gearshape", help: "Settings") {
                openSettingsAndCompleteOnboarding()
            }
            if !needsOnboarding {
                RefreshButton(
                    isLoading: appState.isLoading,
                    isEnabled: appState.isActive && appState.hasEnabledDataSource
                ) {
                    appState.refreshNow()
                }
            }
            footerButton("power", help: "Quit Claude Meter") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func footerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Self-contained refresh control. The spinner is driven by `TimelineView(.animation)`
    /// rather than a `.repeatForever` animation so the forever-repeating transaction can't
    /// leak into the footer's per-second relayout (the "Updated Ns ago" counter), which made
    /// the icon drift out of its slot. The fixed frame keeps the layout slot stable while spinning.
    private struct RefreshButton: View {
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
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(isLoading || !isEnabled)
        }

        private var icon: some View {
            Image(systemName: "arrow.clockwise")
                .font(.body)
                .foregroundStyle(.secondary)
        }

        private static func angle(at date: Date) -> Double {
            // One full revolution per second, continuous.
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
        if elapsed < 5   { return "Just updated" }
        if elapsed < 60  { return "Updated \(elapsed)s ago" }
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
            || Self.claudeMeterDirectoryExists {
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
            || err.localizedCaseInsensitiveContains("session key") {
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
            || err.localizedCaseInsensitiveContains("session key") {
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
            source: SourceInfo(cliPath: "/Users/jewei/.claude/stats-cache.json", command: "stats-cache"),
            session: SessionInfo(activeModel: "claude-sonnet-4-6"),
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: 25,
                    resetsAt: Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)),
                    rawValueText: "245 msgs"
                ),
                currentWeekAllModels: LimitWindow(
                    percentUsed: 82,
                    resetsAt: Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)),
                    rawValueText: "1482 msgs"
                )
            ),
            state: SnapshotState(status: .ok, severity: .warning)
        )
        let store = SnapshotStore(directory: FileManager.default.temporaryDirectory)
        try? store.writeLatest(snap)
        let pipeline = CachedSnapshotPipeline(store: store)
        return AppState(pipeline: pipeline, initialSnapshot: snap)
    }
}

#Preview {
    PopoverView()
        .environmentObject(AppState.preview)
        .frame(width: 320)
}
