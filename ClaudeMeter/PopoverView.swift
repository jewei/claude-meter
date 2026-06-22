import SwiftUI
import ClaudeMeterCore

struct PopoverView: View {
    @EnvironmentObject var appState: AppState
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.cmBackground.opacity(0.45)
            VStack(spacing: 0) {
                headerBar
                Divider().opacity(0.15)
                mainContent
                Divider().opacity(0.15)
                footerBar
            }
        }
        .background(.ultraThinMaterial)
        .onReceive(ticker) { now = $0 }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Claude Meter")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
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
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Claude CLI not found")
                .font(.system(size: 13, weight: .medium))
            Text("Open Settings to configure the CLI path.")
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func usageState(_ snap: ClaudeUsageSnapshot) -> some View {
        VStack(spacing: 0) {
            if appState.lastError != nil {
                pollErrorNotice
                Divider().opacity(0.1)
            }
            if appState.isStale {
                staleNotice
                Divider().opacity(0.1)
            }
            UsageCardView(
                label: "SESSION",
                window: snap.limits.currentSession,
                now: now
            )
            Divider().opacity(0.1).padding(.horizontal, 16)
            UsageCardView(
                label: "WEEK (ALL MODELS)",
                window: snap.limits.currentWeekAllModels,
                now: now
            )
            if let model = snap.session?.activeModel {
                Divider().opacity(0.1).padding(.horizontal, 16)
                modelRow(model)
            }
        }
    }

    // MARK: - Stale notice

    private var pollErrorNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
            Text(pollErrorText)
                .font(.system(size: 12))
                .lineLimit(2)
        }
        .foregroundStyle(Color.cmWarning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.cmWarning.opacity(0.08))
    }

    private var pollErrorText: String {
        let err = appState.lastError ?? ""
        if err.contains("authenticated") || err.contains("not logged") {
            return "Refresh failed — run: claude login"
        }
        if err.contains("timeout") { return "Refresh failed — CLI timed out" }
        if err.contains("usage-limit") || err.contains("No CLI output") {
            return "Refresh failed — could not parse output"
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

    // MARK: - Model row

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
        HStack {
            Text(updatedText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            Button("Refresh") {
                appState.refreshNow()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .disabled(appState.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var updatedText: String {
        guard let polledAt = appState.lastPolledAt else { return "Not yet polled" }
        let elapsed = Int(now.timeIntervalSince(polledAt))
        if elapsed < 5   { return "Just updated" }
        if elapsed < 60  { return "Updated \(elapsed)s ago" }
        let mins = elapsed / 60
        return "Updated \(mins)m ago"
    }

    // MARK: - Error helpers

    private var errorTitle: String {
        let err = appState.lastError ?? ""
        if err.contains("cliNotFound") { return "Claude CLI not found" }
        if err.contains("timeout")     { return "Claude CLI timed out" }
        if err.contains("unauthenticated") || err.contains("not logged") || err.contains("authenticated") {
            return "Claude not logged in"
        }
        if err.contains("usage-limit") || err.contains("No CLI output") || err.contains("parse") {
            return "Could not parse output"
        }
        return "Could not reach Claude"
    }

    private var errorHint: String? {
        let err = appState.lastError ?? ""
        if err.contains("cliNotFound")  { return "Open Settings to configure the CLI path." }
        if err.contains("unauthenticated") || err.contains("not logged") || err.contains("authenticated") {
            return "Run: claude login"
        }
        if err.contains("usage-limit") || err.contains("No CLI output") {
            return "Check Diagnostics for parser details."
        }
        return nil
    }
}

// MARK: - Preview helpers

extension AppState {
    static var preview: AppState {
        let snap = ClaudeUsageSnapshot(
            parserVersion: "0.1.0",
            createdAt: Date(),
            lastSuccessfulPollAt: Date(),
            source: SourceInfo(cliPath: "/opt/homebrew/bin/claude", command: "claude status"),
            session: SessionInfo(activeModel: "claude-opus-4-8"),
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: 25,
                    resetsAt: Date().addingTimeInterval(2700),
                    rawResetText: "2:50pm (Asia/Kuala_Lumpur)"
                ),
                currentWeekAllModels: LimitWindow(
                    percentUsed: 82,
                    resetsAt: Date().addingTimeInterval(5 * 86400),
                    rawResetText: "Jun 27 at 3pm (Asia/Kuala_Lumpur)"
                )
            ),
            state: SnapshotState(status: .ok, severity: .warning)
        )
        let store = SnapshotStore(directory: FileManager.default.temporaryDirectory)
        let pipeline = SnapshotPipeline(
            runner: MockCommandRunner(statusOutput: ""),
            parser: ClaudeOutputParser(cliPath: "/opt/homebrew/bin/claude"),
            store: store
        )
        return AppState(pipeline: pipeline, initialSnapshot: snap)
    }
}

#Preview {
    PopoverView()
        .environmentObject(AppState.preview)
        .frame(width: 320)
}
