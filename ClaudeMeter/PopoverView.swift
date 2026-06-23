import SwiftUI
import ClaudeMeterCore
import AppKit

struct PopoverView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var now = Date()
    @State private var showOnboarding = false

    private var usageThresholds: UsageThresholds {
        AppState.currentThresholds()
    }

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if appState.updateAvailable {
                updateAvailableNotice
                Divider()
            }
            mainContent
            Divider()
            footerBar
        }
        .background(.regularMaterial)
        .onReceive(ticker) { now = $0 }
        .onAppear {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Claude Meter")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Button {
                appState.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(appState.isLoading)
            .rotationEffect(appState.isLoading ? .degrees(360) : .zero)
            .animation(
                appState.isLoading
                    ? .linear(duration: 1).repeatForever(autoreverses: false)
                    : .default,
                value: appState.isLoading
            )
        }
        .padding(.horizontal, 14)
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
            Text("No usage data yet")
                .font(.system(size: 13, weight: .medium))
            Text("Open Claude Code so the statusline bridge can publish usage, or connect OAuth/claude.ai in Settings.")
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
                thresholds: usageThresholds
            )
            Divider().padding(.horizontal, 14)
            UsageCardView(
                label: "This Week",
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
            Text(updatedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Refresh") {
                appState.refreshNow()
            }
            .buttonStyle(.plain)
            .font(.body)
            .foregroundStyle(.primary)
            .disabled(appState.isLoading)
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

// MARK: - First-run onboarding

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    private var isAPIConnected: Bool {
        ClaudeAIKeychain.load() != nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

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
            } else {
                Text("No usage data found yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Open Claude Code to publish statusline data, or connect OAuth/claude.ai in Settings → Data.")
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
