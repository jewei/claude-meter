import SwiftUI
import ServiceManagement
import AppKit
import ClaudeMeterCore

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            CLISettingsTab(appState: appState)
                .tabItem { Label("CLI", systemImage: "terminal") }
            DisplaySettingsTab()
                .tabItem { Label("Display", systemImage: "eye") }
            NotificationsSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AdvancedSettingsTab(appState: appState)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 460, height: 320)
    }
}

// MARK: - CLI tab

private struct CLISettingsTab: View {
    let appState: AppState

    @AppStorage("claudeCliPath") private var claudeCliPath = ""
    @AppStorage("statusArguments") private var statusArguments = "status"
    @AppStorage("statsArguments") private var statsArguments = "stats"
    @AppStorage("cliTimeoutSeconds") private var cliTimeoutSeconds = 5.0
    @AppStorage("pollIntervalActiveSeconds") private var pollIntervalActiveSeconds = 15.0
    @AppStorage("pollIntervalBackgroundSeconds") private var pollIntervalBackgroundSeconds = 60.0
    @AppStorage("staleAfterSeconds") private var staleAfterSeconds = 180.0

    @State private var cliValidationMessage: String? = nil

    var body: some View {
        Form {
            Section("Binary") {
                HStack {
                    TextField("Auto-detect", text: $claudeCliPath)
                        .font(.system(.body, design: .monospaced))
                    Button("Browse…") { browse() }
                        .buttonStyle(.borderless)
                    Button("Test") { test() }
                        .buttonStyle(.borderless)
                        .disabled(effectiveCLIPath.isEmpty)
                }
                if let msg = cliValidationMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.hasPrefix("✓") ? Color.cmNormal : Color.cmCritical)
                }
                Text("Leave blank to use the auto-detected path: \(autodetectedPath ?? "not found")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Commands") {
                LabeledContent("Status subcommand") {
                    TextField("status", text: $statusArguments)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 140)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Stats subcommand") {
                    TextField("stats (leave blank to skip)", text: $statsArguments)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 200)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Timing") {
                LabeledContent("CLI timeout") {
                    HStack {
                        Slider(value: $cliTimeoutSeconds, in: 2...30, step: 1)
                            .frame(width: 120)
                        Text("\(Int(cliTimeoutSeconds))s")
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                LabeledContent("Poll (popover open)") {
                    HStack {
                        Slider(value: $pollIntervalActiveSeconds, in: 5...60, step: 5)
                            .frame(width: 120)
                        Text("\(Int(pollIntervalActiveSeconds))s")
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                LabeledContent("Poll (background)") {
                    HStack {
                        Slider(value: $pollIntervalBackgroundSeconds, in: 15...300, step: 15)
                            .frame(width: 120)
                        Text("\(Int(pollIntervalBackgroundSeconds))s")
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                LabeledContent("Mark stale after") {
                    HStack {
                        Slider(value: $staleAfterSeconds, in: 60...600, step: 30)
                            .frame(width: 120)
                        Text("\(Int(staleAfterSeconds))s")
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: claudeCliPath)       { _, _ in rebuild() }
        .onChange(of: statusArguments)     { _, _ in rebuild() }
        .onChange(of: statsArguments)      { _, _ in rebuild() }
        .onChange(of: cliTimeoutSeconds)   { _, _ in rebuild() }
        .onChange(of: staleAfterSeconds)  { _, _ in AppGroupConfig.syncDisplaySettings() }
    }

    private var effectiveCLIPath: String {
        let stored = claudeCliPath.trimmingCharacters(in: .whitespaces)
        return stored.isEmpty ? (CLIPathDetector.detect() ?? "") : stored
    }

    private var autodetectedPath: String? {
        CLIPathDetector.detect()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select the claude binary"
        if panel.runModal() == .OK, let url = panel.url {
            claudeCliPath = url.path
        }
    }

    private func test() {
        let path = effectiveCLIPath
        if CLIPathDetector.verify(path: path) {
            cliValidationMessage = "✓ Executable found at \(path)"
        } else {
            cliValidationMessage = "✗ Not found or not executable: \(path)"
        }
    }

    private func rebuild() {
        appState.rebuildPipeline()
    }
}

// MARK: - Display tab

private struct DisplaySettingsTab: View {
    @AppStorage("privacyMode") private var privacyMode: PrivacyMode = .workSafe
    @AppStorage("warningThresholdPercent") private var warningThresholdPercent = 80.0
    @AppStorage("criticalThresholdPercent") private var criticalThresholdPercent = 95.0

    var body: some View {
        Form {
            Section("Privacy Mode") {
                Picker("Privacy", selection: $privacyMode) {
                    ForEach(PrivacyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(privacyMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Severity Thresholds") {
                LabeledContent("Warning at") {
                    HStack {
                        Slider(value: $warningThresholdPercent, in: 50...90, step: 5)
                            .frame(width: 140)
                        Text("\(Int(warningThresholdPercent))%")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("Critical at") {
                    HStack {
                        Slider(value: $criticalThresholdPercent, in: 60...100, step: 5)
                            .frame(width: 140)
                        Text("\(Int(criticalThresholdPercent))%")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Text("Threshold changes apply immediately to display and notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { AppGroupConfig.syncDisplaySettings() }
        .onChange(of: warningThresholdPercent) { _, newWarning in
            if criticalThresholdPercent <= newWarning {
                criticalThresholdPercent = min(100, newWarning + 5)
            }
            AppGroupConfig.syncDisplaySettings()
        }
        .onChange(of: criticalThresholdPercent) { _, newCritical in
            if newCritical <= warningThresholdPercent {
                criticalThresholdPercent = min(100, warningThresholdPercent + 5)
            }
            AppGroupConfig.syncDisplaySettings()
        }
        .onChange(of: privacyMode) { _, _ in
            AppGroupConfig.syncDisplaySettings()
        }
    }
}

// MARK: - Notifications tab

private struct NotificationsSettingsTab: View {
    @AppStorage("enableNotifications") private var enableNotifications = true

    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: $enableNotifications)
                Text("Posts a notification when session or weekly usage crosses the warning or critical threshold. One notification per threshold per reset window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Triggers") {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.cmWarning)
                    Text("Warning threshold crossed")
                }
                .foregroundStyle(enableNotifications ? .primary : .secondary)
                HStack {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(Color.cmCritical)
                    Text("Critical threshold crossed")
                }
                .foregroundStyle(enableNotifications ? .primary : .secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Advanced tab

private struct AdvancedSettingsTab: View {
    let appState: AppState

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("enableDiagnosticsRawOutput") private var enableDiagnosticsRawOutput = false
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 180.0
    @Environment(\.openWindow) private var openWindow

    @State private var showingDiagnostics = false

    var body: some View {
        Form {
            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in applyLaunchAtLogin(newValue) }
                    .onAppear { syncLaunchAtLoginFromSystem() }
            }

            Section("Mini Monitor") {
                Button("Open Mini Monitor…") { openWindow(id: "mini-monitor") }
                    .buttonStyle(.borderless)
                Text("A compact always-on-top window showing live session and weekly usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                LabeledContent("Retention") {
                    HStack {
                        Slider(value: $historyRetentionDays, in: 7...365, step: 1)
                            .frame(width: 140)
                        Text("\(Int(historyRetentionDays))d")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Text("Poll snapshots older than this are removed from the local history database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: historyRetentionDays) { _, newValue in
                appState.setHistoryRetentionDays(Int(newValue))
            }

            Section("Diagnostics") {
                Toggle("Record raw CLI output", isOn: $enableDiagnosticsRawOutput)
                    .onChange(of: enableDiagnosticsRawOutput) { _, _ in appState.rebuildPipeline() }
                Text("Stores the raw CLI output to disk for debugging. Disabled by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Diagnostics…") { showingDiagnostics = true }
                    .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView()
                .environmentObject(appState)
                .frame(minWidth: 480, minHeight: 380)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    private func syncLaunchAtLoginFromSystem() {
        let enabled = SMAppService.mainApp.status == .enabled
        if launchAtLogin != enabled {
            launchAtLogin = enabled
        }
    }
}
