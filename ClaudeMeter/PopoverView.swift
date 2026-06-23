import SwiftUI
import ClaudeMeterCore
import AppKit

struct PopoverView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.openWindow) private var openWindow
    @State private var now = Date()
    @State private var showOnboarding = false
    @State private var showHistory = false

    private var usageThresholds: UsageThresholds {
        AppState.currentThresholds()
    }

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.cmBackground.opacity(0.45)
            VStack(spacing: 0) {
                headerBar
                Divider().opacity(0.15)
                if appState.updateAvailable {
                    updateAvailableNotice
                    Divider().opacity(0.1)
                }
                mainContent
                Divider().opacity(0.15)
                footerBar
            }
        }
        .background(.ultraThinMaterial)
        .onReceive(ticker) { now = $0 }
        .onAppear {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
                .environmentObject(appState)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Claude Meter")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            Button {
                appState.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(appState.isLoading)
            .rotationEffect(appState.isLoading ? .degrees(360) : .zero)
            .animation(
                appState.isLoading
                    ? .linear(duration: 1).repeatForever(autoreverses: false)
                    : .default,
                value: appState.isLoading
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if appState.snapshot == nil && appState.isLoading {
            loadingState
        } else if let snap = appState.snapshot {
            usageState(snap)
        } else if appState.lastError != nil {
            errorState
        } else {
            setupState
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().scaleEffect(0.8)
            Text("Checking Claude…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var setupState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Stats cache not found")
                .font(.system(size: 13, weight: .medium))
            Text("Make sure Claude Code has been used at least once. Expected at ~/.claude/stats-cache.json")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    private var errorState: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(Color.cmCritical)
            Text(errorTitle)
                .font(.system(size: 13, weight: .medium))
            if let hint = errorHint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if shouldOfferSettings {
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func usageState(_ snap: ClaudeUsageSnapshot) -> some View {
        VStack(spacing: 0) {
            if let apiWarning = appState.primarySourceWarning {
                apiDegradedNotice(apiWarning)
                Divider().opacity(0.1)
            } else if appState.lastError != nil {
                pollErrorNotice
                Divider().opacity(0.1)
            }
            if appState.isStale {
                staleNotice
                Divider().opacity(0.1)
            }
            UsageCardView(
                label: "CURRENT SESSION",
                window: snap.limits.currentSession,
                now: now,
                thresholds: usageThresholds
            )
            Divider().opacity(0.1).padding(.horizontal, 16)
            UsageCardView(
                label: "THIS WEEK",
                window: snap.limits.currentWeekAllModels,
                now: now,
                thresholds: usageThresholds
            )
        }
    }

    // MARK: - Notices

    private var updateAvailableNotice: some View {
        Button {
            appState.checkForUpdates()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11))
                Text("Update available — click to install")
                    .font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(Color.cmNormal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.cmNormal.opacity(0.08))
        }
        .buttonStyle(.plain)
    }

    private var pollErrorNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
            Text(pollErrorText)
                .font(.system(size: 12))
                .lineLimit(3)
        }
        .foregroundStyle(Color.cmWarning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.cmWarning.opacity(0.08))
    }

    private func apiDegradedNotice(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 12))
                .lineLimit(3)
        }
        .foregroundStyle(Color.cmWarning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.cmWarning.opacity(0.08))
    }

    private var pollErrorText: String {
        let err = appState.lastError ?? ""
        if err.localizedCaseInsensitiveContains("session expired")
            || err.localizedCaseInsensitiveContains("session key") {
            return err
        }
        if err.contains("Stats cache not found") {
            return "Stats cache missing — use Claude Code to generate it"
        }
        if err.contains("decode") || err.contains("data couldn't be read") {
            return "Refresh failed — could not parse stats cache"
        }
        return "Refresh failed — showing last known data"
    }

    private var staleNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 11))
            Text("Data may be outdated")
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.cmWarning.opacity(0.08))
    }

    // MARK: - Model row (kept for stats-cache fallback path)

    private func modelRow(_ model: String) -> some View {
        HStack {
            Text("Model")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(model)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 8) {
            Text(updatedText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            Button {
                showHistory = true
            } label: {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Show usage history")
            Button {
                openWindow(id: "mini-monitor")
            } label: {
                Image(systemName: "pip")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Open mini monitor")
            Button("Refresh") {
                appState.refreshNow()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .disabled(appState.isLoading)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Quit Claude Meter")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var updatedText: String {
        guard let polledAt = appState.snapshot?.lastSuccessfulPollAt ?? appState.lastPolledAt else {
            return "Not yet polled"
        }
        let elapsed = Int(now.timeIntervalSince(polledAt))
        if elapsed < 5   { return "Just updated" }
        if elapsed < 60  { return "Updated \(elapsed)s ago" }
        let mins = elapsed / 60
        return "Updated \(mins)m ago"
    }

    // MARK: - Error helpers

    private var errorTitle: String {
        let err = appState.lastError ?? ""
        if err.localizedCaseInsensitiveContains("session expired")
            || err.localizedCaseInsensitiveContains("session key") {
            return "Session expired"
        }
        if err.contains("Stats cache not found") { return "Stats cache not found" }
        if err.contains("decode") || err.contains("data couldn't be read") {
            return "Could not read stats cache"
        }
        return "Could not read usage stats"
    }

    private var errorHint: String? {
        let err = appState.lastError ?? ""
        if err.localizedCaseInsensitiveContains("session expired")
            || err.localizedCaseInsensitiveContains("session key") {
            return "Update your session key and org ID in Settings → Data."
        }
        if err.contains("Stats cache not found") {
            return "Connect claude.ai in Settings, or use Claude Code to generate ~/.claude/stats-cache.json"
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

// MARK: - First-run onboarding

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    private var isAPIConnected: Bool {
        ClaudeAIKeychain.load() != nil
    }

    private var cacheExists: Bool {
        FileManager.default.fileExists(atPath: StatsCacheReader.defaultPath.path)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 40))
                .foregroundStyle(Color.cmNormal)

            Text("Welcome to Claude Meter")
                .font(.title2.bold())

            if isAPIConnected {
                Text("Connected to claude.ai for exact usage percentages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Message counts from your Claude Code journal supplement the display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if cacheExists {
                Text("Using Claude Code stats at ~/.claude/stats-cache.json")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("For exact usage percentages, connect your claude.ai session in Settings → Data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("No usage data found yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Connect claude.ai in Settings → Data, or use Claude Code in a terminal first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Open Settings") { openSettings() }
                Button("Continue") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 420)
    }

    private func finish() {
        hasCompletedOnboarding = true
        dismiss()
    }
}

// MARK: - Preview helpers

extension AppState {
    static var preview: AppState {
        let snap = ClaudeUsageSnapshot(
            parserVersion: "stats-cache-1.0",
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
        let pipeline = StatsCachePipeline(store: store)
        return AppState(pipeline: pipeline, initialSnapshot: snap)
    }
}

#Preview {
    PopoverView()
        .environmentObject(AppState.preview)
        .frame(width: 320)
}
