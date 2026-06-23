import SwiftUI
import ClaudeMeterCore
import AppKit

struct PopoverView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
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

    @ViewBuilder
    private var mainContent: some View {
        if needsOnboarding {
            onboardingContent
        } else if !appState.isActive {
            if let snap = appState.snapshot {
                usageState(snap)
            } else {
                inactiveState
            }
        } else if !appState.hasEnabledDataSource {
            noSourcesState
        } else if appState.snapshot == nil && appState.isLoading {
            loadingState
        } else if let snap = appState.snapshot {
            usageState(snap)
        } else if appState.lastError != nil {
            errorState
        } else {
            setupState
        }
    }

    private var onboardingContent: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

            Image(nsImage: NSApplication.shared.applicationIconImage)
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
                Button {
                    appState.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .disabled(appState.isLoading || !appState.isActive || !appState.hasEnabledDataSource)
                .rotationEffect(appState.isLoading ? .degrees(360) : .zero)
                .animation(
                    appState.isLoading
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default,
                    value: appState.isLoading
                )
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
