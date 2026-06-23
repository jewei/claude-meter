import SwiftUI
import ServiceManagement
import AppKit
import ClaudeMeterCore

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            DataSettingsTab(appState: appState)
                .tabItem { Label("Data", systemImage: "doc.text") }
            DisplaySettingsTab()
                .tabItem { Label("Display", systemImage: "eye") }
            NotificationsSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AdvancedSettingsTab(appState: appState)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 480, height: 380)
        .background(FloatingWindowAccessor())
    }
}

// MARK: - Window level shim

/// Makes the host window float above normal app windows, so the settings panel
/// stays visible over other apps (needed because this is a LSUIElement menu bar app).
private struct FloatingWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.level = .floating
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Data tab

private struct DataSettingsTab: View {
    let appState: AppState

    @AppStorage("pollIntervalActiveSeconds") private var pollIntervalActiveSeconds = 15.0
    @AppStorage("pollIntervalBackgroundSeconds") private var pollIntervalBackgroundSeconds = 60.0
    @AppStorage("staleAfterSeconds") private var staleAfterSeconds = 180.0

    @State private var sessionKey = ""
    @State private var orgId = ""
    @State private var isConnected = false
    @State private var connectionStatus = ""
    @State private var showSessionKey = false
    @State private var isTesting = false
    @State private var testResult = ""

    var body: some View {
        Form {
            Section("Claude.ai Connection") {
                if isConnected {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Connected")
                        }
                    }
                    LabeledContent("Org ID") {
                        Text(DiagnosticsSanitizer.sanitize(orgId))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button(isTesting ? "Testing…" : "Test connection") { testConnection() }
                            .buttonStyle(.borderless)
                            .disabled(isTesting)
                        Button("Disconnect") { disconnect() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("Error") ? .red : .green)
                    }
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        Text("Session key")
                            .frame(width: 90, alignment: .leading)
                        Group {
                            if showSessionKey {
                                TextField("", text: $sessionKey,
                                          prompt: Text("sk-ant-sid02-…").foregroundColor(.secondary))
                            } else {
                                SecureField("", text: $sessionKey,
                                            prompt: Text("sk-ant-sid02-…").foregroundColor(.secondary))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .textContentType(.password)
                        .frame(width: 260)
                        Button {
                            showSessionKey.toggle()
                        } label: {
                            Image(systemName: showSessionKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(showSessionKey ? "Hide" : "Show (enables paste)")
                    }

                    HStack(alignment: .center, spacing: 10) {
                        Text("Org ID")
                            .frame(width: 90, alignment: .leading)
                        TextField("", text: $orgId,
                                  prompt: Text("UUID").foregroundColor(.secondary))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 260)
                    }
                    if !connectionStatus.isEmpty {
                        Text(connectionStatus)
                            .font(.caption)
                            .foregroundStyle(connectionStatus.hasPrefix("Error") ? .red : .secondary)
                    }
                    Button("Connect") { connect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(sessionKey.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  orgId.trimmingCharacters(in: .whitespaces).isEmpty)
                    Text("Find in browser: DevTools → Application → Cookies → claude.ai → sessionKey. Org ID is in the lastActiveOrg cookie.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Polling") {
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
        .onAppear { loadKeychainState() }
        .onChange(of: staleAfterSeconds)   { _, _ in AppGroupConfig.syncDisplaySettings() }
    }

    private func loadKeychainState() {
        if let creds = ClaudeAIKeychain.load() {
            orgId = creds.orgId
            isConnected = true
        } else {
            isConnected = false
        }
    }

    private func connect() {
        let sk = sessionKey.trimmingCharacters(in: .whitespaces)
        let org = orgId.trimmingCharacters(in: .whitespaces)
        guard !sk.isEmpty, !org.isEmpty else { return }
        guard CredentialValidator.isValidSessionKey(sk) else {
            connectionStatus = "Error: invalid session key format"
            return
        }
        guard let normalizedOrg = CredentialValidator.normalizedOrgId(org) else {
            connectionStatus = "Error: org ID must be a valid UUID"
            return
        }
        if ClaudeAIKeychain.save(sessionKey: sk, orgId: normalizedOrg) {
            sessionKey = ""
            isConnected = true
            connectionStatus = ""
            rebuild()
        } else {
            connectionStatus = "Error: could not save to Keychain"
        }
    }

    private func disconnect() {
        ClaudeAIKeychain.delete()
        sessionKey = ""
        orgId = ""
        isConnected = false
        connectionStatus = ""
        rebuild()
    }



    private func testConnection() {
        guard let creds = ClaudeAIKeychain.load() else { return }
        isTesting = true
        testResult = ""
        Task {
            defer { isTesting = false }
            let client = ClaudeAIUsageClient(sessionKey: creds.sessionKey, orgId: creds.orgId)
            do {
                let usage = try await client.fetchUsage()
                testResult = "Session \(Int(usage.sessionPercent))%  ·  Week \(Int(usage.weekPercent))%"
            } catch {
                testResult = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func rebuild() {
        appState.rebuildPipeline()
    }
}

// MARK: - Display tab

private struct DisplaySettingsTab: View {
    @AppStorage("warningThresholdPercent") private var warningThresholdPercent = 80.0
    @AppStorage("criticalThresholdPercent") private var criticalThresholdPercent = 95.0

    var body: some View {
        Form {
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
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 180.0
    @AppStorage("SUEnableAutomaticChecks") private var automaticallyCheckForUpdates = true
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

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $automaticallyCheckForUpdates)
                Button("Check for Updates…") { appState.checkForUpdates() }
                    .buttonStyle(.borderless)
            }

            Section("Diagnostics") {
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
