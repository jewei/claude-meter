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
        .frame(width: 480, height: 500)
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

private enum OAuthSetupState: Equatable {
    case idle
    case promptAuto
    case promptNoAuto
    case manualEntry
    case verifying
    case connectedAuto
    case connectedManual
    case error(String)
}

private struct OAuthConnectionSection: View {
    let appState: AppState

    @AppStorage(AppSettings.oauthSourceEnabledKey) private var oauthSourceEnabled = true
    @AppStorage("oauthMode") private var oauthMode = ""
    @State private var state: OAuthSetupState = .idle
    @State private var showAccessToken = false
    @State private var showRefreshToken = false
    @State private var manualAccess = ""
    @State private var manualRefresh = ""
    @State private var testResult = ""
    @State private var isTesting = false

    var body: some View {
        Section("2. Claude Code OAuth") {
            Toggle("Enable OAuth usage API", isOn: $oauthSourceEnabled)
            if oauthSourceEnabled {
                stateContent
            } else {
                Text("Skipped while this method is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Second priority. Uses Claude Code OAuth credentials from Keychain when active.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { loadState() }
        .onChange(of: oauthSourceEnabled) { _, _ in appState.rebuildPipeline() }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle:
            EmptyView()

        case .promptAuto:
            LabeledContent("Detected") {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text("Claude Code token").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button("Use auto-detected token") { useAutoDetected() }
                    .buttonStyle(.borderedProminent)
                Button("Enter manually") { state = .manualEntry }
                    .buttonStyle(.borderless)
            }

        case .promptNoAuto:
            LabeledContent("Detected") {
                Text("No Claude Code credentials found").foregroundStyle(.secondary)
            }
            Button("Enter tokens manually") { state = .manualEntry }
                .buttonStyle(.borderless)

        case .manualEntry:
            HStack(alignment: .center, spacing: 10) {
                Text("Access Token")
                    .frame(width: 100, alignment: .leading)
                Group {
                    if showAccessToken {
                        TextField("", text: $manualAccess,
                                  prompt: Text("oidc-…").foregroundColor(.secondary))
                    } else {
                        SecureField("", text: $manualAccess,
                                    prompt: Text("oidc-…").foregroundColor(.secondary))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .textContentType(.password)
                .frame(width: 240)
                Button {
                    showAccessToken.toggle()
                } label: {
                    Image(systemName: showAccessToken ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            HStack(alignment: .center, spacing: 10) {
                Text("Refresh Token")
                    .frame(width: 100, alignment: .leading)
                Group {
                    if showRefreshToken {
                        TextField("", text: $manualRefresh,
                                  prompt: Text("Refresh token").foregroundColor(.secondary))
                    } else {
                        SecureField("", text: $manualRefresh,
                                    prompt: Text("Refresh token").foregroundColor(.secondary))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .textContentType(.password)
                .frame(width: 240)
                Button {
                    showRefreshToken.toggle()
                } label: {
                    Image(systemName: showRefreshToken ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 10) {
                Button("Save and connect") { saveManual() }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualAccess.trimmingCharacters(in: .whitespaces).isEmpty ||
                              manualRefresh.trimmingCharacters(in: .whitespaces).isEmpty)
                if oauthMode.isEmpty {
                    Button("Cancel") {
                        state = OAuthKeychain.load() != nil ? .promptAuto : .promptNoAuto
                    }
                    .buttonStyle(.borderless)
                }
            }

        case .verifying:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Verifying…").foregroundStyle(.secondary)
            }

        case .connectedAuto, .connectedManual:
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(state == .connectedManual ? "Connected · manual" : "Connected · auto-detected")
                }
            }
            if !testResult.isEmpty {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("Error") ? .red : .green)
            }
            HStack(spacing: 12) {
                Button(isTesting ? "Testing…" : "Test") { testOAuth() }
                    .buttonStyle(.borderless)
                    .disabled(isTesting)
                Button("Disconnect") { disconnect() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }

        case .error(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Retry") { retryAuto() }
                    .buttonStyle(.borderless)
                Button("Enter manually") { state = .manualEntry }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func loadState() {
        switch oauthMode {
        case "auto":   state = .connectedAuto
        case "manual": state = OAuthKeychain.loadManual() != nil ? .connectedManual : .manualEntry
        default:       state = OAuthKeychain.load() != nil ? .promptAuto : .promptNoAuto
        }
    }

    private func useAutoDetected() {
        guard let creds = OAuthKeychain.load() else {
            state = .error("Claude Code credentials not found in Keychain")
            return
        }
        state = .verifying
        Task {
            do {
                let (s, w) = try await OAuthPipeline.verify(credentials: creds)
                oauthSourceEnabled = true
                oauthMode = "auto"
                testResult = "Session \(Int(s))%  ·  Week \(Int(w))%"
                state = .connectedAuto
                appState.rebuildPipeline()
                appState.refreshNow()
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func saveManual() {
        let at = manualAccess.trimmingCharacters(in: .whitespaces)
        let rt = manualRefresh.trimmingCharacters(in: .whitespaces)
        guard !at.isEmpty, !rt.isEmpty else { return }
        OAuthKeychain.saveManual(accessToken: at, refreshToken: rt)
        state = .verifying
        Task {
            do {
                guard let creds = OAuthKeychain.loadManual() else { throw URLError(.badServerResponse) }
                let (s, w) = try await OAuthPipeline.verify(credentials: creds)
                oauthSourceEnabled = true
                oauthMode = "manual"
                testResult = "Session \(Int(s))%  ·  Week \(Int(w))%"
                manualAccess = ""
                manualRefresh = ""
                state = .connectedManual
                appState.rebuildPipeline()
                appState.refreshNow()
            } catch {
                OAuthKeychain.deleteManual()
                state = .error("Verification failed: \(error.localizedDescription)")
            }
        }
    }

    private func retryAuto() {
        guard let creds = OAuthKeychain.load() else {
            state = .promptNoAuto
            return
        }
        state = .verifying
        Task {
            do {
                let (s, w) = try await OAuthPipeline.verify(credentials: creds)
                oauthSourceEnabled = true
                oauthMode = "auto"
                testResult = "Session \(Int(s))%  ·  Week \(Int(w))%"
                state = .connectedAuto
                appState.rebuildPipeline()
                appState.refreshNow()
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func testOAuth() {
        let creds = oauthMode == "manual" ? OAuthKeychain.loadManual() : OAuthKeychain.load()
        guard let creds else { return }
        isTesting = true
        testResult = ""
        Task {
            defer { isTesting = false }
            do {
                let (s, w) = try await OAuthPipeline.verify(credentials: creds)
                testResult = "Session \(Int(s))%  ·  Week \(Int(w))%"
            } catch {
                testResult = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func disconnect() {
        if oauthMode == "manual" { OAuthKeychain.deleteManual() }
        oauthMode = ""
        testResult = ""
        manualAccess = ""
        manualRefresh = ""
        appState.rebuildPipeline()
        state = OAuthKeychain.load() != nil ? .promptAuto : .promptNoAuto
    }
}

private struct DataSettingsTab: View {
    let appState: AppState

    @AppStorage(AppSettings.statuslineSourceEnabledKey) private var statuslineSourceEnabled = true
    @AppStorage(AppSettings.claudeAISourceEnabledKey) private var claudeAISourceEnabled = true

    @State private var sessionKey = ""
    @State private var orgId = ""
    @State private var isConnected = false
    @State private var connectionStatus = ""
    @State private var showSessionKey = false
    @State private var isTesting = false
    @State private var testResult = ""

    var body: some View {
        Form {
            Section("Global") {
                Toggle("Active", isOn: activeBinding)
                Text(appState.isActive
                    ? "Claude Meter refreshes usage once per minute while at least one data method is enabled."
                    : "Paused. No usage data is fetched until you turn Active back on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("1. Statusline Bridge") {
                Toggle("Enable Statusline Bridge", isOn: $statuslineSourceEnabled)
                Text("Top priority. When active, Claude Meter checks the statusline bridge once per minute and falls through to lower enabled methods only when it is stale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            OAuthConnectionSection(appState: appState)

            Section("3. Claude.ai Session") {
                Toggle("Enable claude.ai usage API", isOn: $claudeAISourceEnabled)
                if !claudeAISourceEnabled {
                    Text("Skipped while this method is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isConnected {
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
                    Text("Find sessionKey in browser DevTools → Application → Cookies → claude.ai. Org ID is in the lastActiveOrg cookie.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Third priority. Used only when higher enabled methods are unavailable or stale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { loadKeychainState() }
        .onChange(of: statuslineSourceEnabled) { _, _ in appState.rebuildPipeline() }
        .onChange(of: claudeAISourceEnabled) { _, _ in appState.rebuildPipeline() }
    }

    private var activeBinding: Binding<Bool> {
        Binding(
            get: { appState.isActive },
            set: { appState.setActive($0) }
        )
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
            claudeAISourceEnabled = true
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
                    HStack(spacing: 8) {
                        Stepper("", value: $warningThresholdPercent, in: 50...90, step: 5)
                            .labelsHidden()
                        Text("\(Int(warningThresholdPercent))%")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("Critical at") {
                    HStack(spacing: 8) {
                        Stepper("", value: $criticalThresholdPercent, in: 60...100, step: 5)
                            .labelsHidden()
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
    @AppStorage("SUEnableAutomaticChecks") private var automaticallyCheckForUpdates = true

    @State private var showingDiagnostics = false

    var body: some View {
        Form {
            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in applyLaunchAtLogin(newValue) }
                    .onAppear { syncLaunchAtLoginFromSystem() }
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
