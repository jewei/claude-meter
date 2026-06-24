import SwiftUI
import ServiceManagement
import AppKit
import ClaudeMeterCore

// MARK: - Root

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            DataSettingsTab(appState: appState)
                .tabItem { Label("Data", systemImage: "cylinder.split.1x2") }
            NotificationsSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AdvancedSettingsTab(appState: appState)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 500)
        .background(FloatingWindowAccessor())
    }
}

// MARK: - Window level shim

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

// MARK: - Shared card chrome

private struct DataSourceCard<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isEnabled: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    Image(systemName: icon)
                        .font(.body.weight(.medium))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            content()
                .padding(.leading, 48)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
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
    @AppStorage(AppSettings.oauthModeKey) private var oauthMode = ""
    @State private var state: OAuthSetupState = .idle
    @State private var showAccessToken = false
    @State private var showRefreshToken = false
    @State private var manualAccess = ""
    @State private var manualRefresh = ""
    @State private var testResult = ""
    @State private var isTesting = false

    var body: some View {
        Group {
            if oauthSourceEnabled {
                stateContent
            }
        }
        .onAppear { loadState() }
    }

    private var isConnected: Bool {
        state == .connectedAuto || state == .connectedManual
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle:
            EmptyView()

        case .promptAuto:
            HStack(spacing: 10) {
                Button("Connect") { useAutoDetected() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Enter manually") { state = .manualEntry }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

        case .promptNoAuto:
            Button("Enter tokens manually") { state = .manualEntry }
                .buttonStyle(.bordered)
                .controlSize(.small)

        case .manualEntry:
            manualEntryFields

        case .verifying:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Verifying…").font(.caption).foregroundStyle(.secondary)
            }

        case .connectedAuto, .connectedManual:
            if isConnected {
                Button {
                    reauthenticate()
                } label: {
                    Label("Re-authenticate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if state == .connectedAuto {
                Text("Reads Claude Code's Keychain; refreshed tokens stay in memory for this session only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !testResult.isEmpty {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("Error") ? .red : .green)
            }

        case .error(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Retry") { retryAuto() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Enter manually") { state = .manualEntry }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var manualEntryFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Access Token")
                    .font(.caption)
                    .frame(width: 88, alignment: .leading)
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
                .font(.system(.caption, design: .monospaced))
                Button { showAccessToken.toggle() } label: {
                    Image(systemName: showAccessToken ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                Text("Refresh Token")
                    .font(.caption)
                    .frame(width: 88, alignment: .leading)
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
                .font(.system(.caption, design: .monospaced))
                Button { showRefreshToken.toggle() } label: {
                    Image(systemName: showRefreshToken ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 10) {
                Button("Save and connect") { saveManual() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(manualAccess.trimmingCharacters(in: .whitespaces).isEmpty ||
                              manualRefresh.trimmingCharacters(in: .whitespaces).isEmpty)
                if oauthMode.isEmpty {
                    Button("Cancel") {
                        state = OAuthKeychain.load() != nil ? .promptAuto : .promptNoAuto
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                if isConnected {
                    Button("Disconnect") { disconnect() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                }
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

    private func reauthenticate() {
        if oauthMode == "manual" {
            state = .manualEntry
        } else {
            useAutoDetected()
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
    @AppStorage(AppSettings.oauthSourceEnabledKey) private var oauthSourceEnabled = true
    @AppStorage(AppSettings.claudeAISourceEnabledKey) private var claudeAISourceEnabled = true
    @AppStorage(AppSettings.cursorSourceEnabledKey) private var cursorSourceEnabled = false

    @State private var cursorStatus = ""
    @State private var cursorStatusGeneration = 0
    @State private var cursorStatusTask: Task<Void, Never>?
    @State private var sessionKey = ""
    @State private var orgId = ""
    @State private var isConnected = false
    @State private var connectionStatus = ""
    @State private var showSessionKey = false
    @State private var isTesting = false
    @State private var testResult = ""
    @State private var isImporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data Sources")
                        .font(.title2.weight(.semibold))
                    Text("Configure how Claude Meter collects your usage data. You can enable multiple sources for redundancy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DataSourceCard(
                    icon: "terminal",
                    iconColor: .primary,
                    title: "Statusline Bridge",
                    subtitle: "Check statusline once per minute.",
                    isEnabled: $statuslineSourceEnabled
                ) { }

                DataSourceCard(
                    icon: "key.fill",
                    iconColor: .yellow,
                    title: "Claude Code OAuth",
                    subtitle: "Use OAuth credentials from Keychain.",
                    isEnabled: $oauthSourceEnabled
                ) {
                    OAuthConnectionSection(appState: appState)
                }

                DataSourceCard(
                    icon: "globe",
                    iconColor: .blue,
                    title: "Claude.ai Session",
                    subtitle: "Use web session usage API.",
                    isEnabled: $claudeAISourceEnabled
                ) {
                    claudeAIContent
                }

                DataSourceCard(
                    icon: "cursorarrow.rays",
                    iconColor: .teal,
                    title: "Cursor",
                    subtitle: "Read Cursor billing-period usage (unofficial API; may break).",
                    isEnabled: $cursorSourceEnabled
                ) {
                    cursorContent
                }
            }
            .padding(20)
        }
        .onAppear { loadKeychainState(); loadCursorStatus() }
        .onChange(of: statuslineSourceEnabled) { _, _ in appState.scheduleRebuildPipeline() }
        .onChange(of: oauthSourceEnabled) { _, _ in appState.scheduleRebuildPipeline() }
        .onChange(of: claudeAISourceEnabled) { _, _ in appState.scheduleRebuildPipeline() }
        .onChange(of: cursorSourceEnabled) { _, enabled in
            loadCursorStatus()
            appState.setCursorSourceEnabled(enabled)
        }
    }

    @ViewBuilder
    private var cursorContent: some View {
        if cursorSourceEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: cursorStatus.hasPrefix("Connected") ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(cursorStatus.hasPrefix("Connected") ? .green : .secondary)
                    Text(cursorStatus.isEmpty ? "Checking…" : cursorStatus)
                }
                if let err = appState.cursorError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(err)
                    }
                    .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func loadCursorStatus() {
        cursorStatusTask?.cancel()
        guard cursorSourceEnabled else {
            cursorStatus = ""
            return
        }
        cursorStatus = ""
        cursorStatusGeneration += 1
        let generation = cursorStatusGeneration
        cursorStatusTask = Task {
            // `detect()` reads state.vscdb via a `sqlite3` subprocess; run it off
            // the main actor so the UI thread doesn't block on a lower-QoS process
            // (priority inversion). Mirrors the browser-import detach below.
            let creds = await Task.detached(priority: .userInitiated) {
                CursorTokenStore.detect()
            }.value
            let status: String
            if let creds {
                let plan = creds.membership.map { " · \($0)" } ?? ""
                let emailPart = creds.email.map { ": \(Self.maskedEmail($0))" } ?? ""
                status = "Connected\(emailPart)\(plan)"
            } else {
                status = "Cursor not detected — sign in to the Cursor app."
            }
            guard !Task.isCancelled, generation == cursorStatusGeneration else { return }
            cursorStatus = status
        }
    }

    private static func maskedEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return "***" }
        let local = parts[0]
        let masked = local.count <= 1 ? "*" : "\(local.prefix(1))***"
        return "\(masked)@\(parts[1])"
    }

    @ViewBuilder
    private var claudeAIContent: some View {
        if claudeAISourceEnabled {
            if let expiredMessage = sessionExpiredMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(expiredMessage)
                }
                .font(.caption)
                .foregroundStyle(.red)
            }

            if isConnected {
                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.hasPrefix("Error") ? .red : .green)
                }
                HStack(spacing: 12) {
                    Button(isTesting ? "Testing…" : "Test connection") { testConnection() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isTesting)
                    Button("Disconnect") { disconnect() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                }
            } else {
                claudeAIConnectFields
            }
        }
    }

    @ViewBuilder
    private var claudeAIConnectFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Session key")
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
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
                .font(.system(.caption, design: .monospaced))
                Button { showSessionKey.toggle() } label: {
                    Image(systemName: showSessionKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                Text("Org ID")
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                TextField("", text: $orgId,
                          prompt: Text("Auto-detect").foregroundColor(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
            if !connectionStatus.isEmpty {
                Text(connectionStatus)
                    .font(.caption)
                    .foregroundStyle(connectionStatus.hasPrefix("Error") ? .red : .secondary)
            }
            HStack(spacing: 8) {
                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(sessionKey.trimmingCharacters(in: .whitespaces).isEmpty || isImporting)
                Button {
                    importFromBrowser()
                } label: {
                    if isImporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Import from browser", systemImage: "arrow.down.doc")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isImporting)
            }
            Text("Import reads the claude.ai session from Chrome, Brave, Edge, Arc, Firefox, or Safari. Or paste sessionKey from DevTools → Application → Cookies → claude.ai. Org ID is detected automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var sessionExpiredMessage: String? {
        let sources = [
            appState.lastError,
            testResult.hasPrefix("Error") ? testResult : nil,
            connectionStatus.hasPrefix("Error") ? connectionStatus : nil
        ]
        for text in sources.compactMap({ $0 }) {
            if text.localizedCaseInsensitiveContains("session expired")
                || text.localizedCaseInsensitiveContains("session key")
                || text.localizedCaseInsensitiveContains("401") {
                return "Session expired. Please login again."
            }
        }
        return nil
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
        guard !sk.isEmpty else { return }
        guard CredentialValidator.isValidSessionKey(sk) else {
            connectionStatus = "Error: invalid session key format"
            return
        }
        // Blank org → resolve it automatically from the session key.
        if org.isEmpty {
            connectionStatus = "Detecting organization…"
            Task {
                do {
                    let resolved = try await ClaudeAIUsageClient.resolveOrgId(sessionKey: sk)
                    finishConnect(sessionKey: sk, orgId: resolved)
                } catch {
                    connectionStatus = "Error: could not detect organization — \(error.localizedDescription)"
                }
            }
            return
        }
        guard let normalizedOrg = CredentialValidator.normalizedOrgId(org) else {
            connectionStatus = "Error: org ID must be a valid UUID"
            return
        }
        finishConnect(sessionKey: sk, orgId: normalizedOrg)
    }

    private func importFromBrowser() {
        isImporting = true
        connectionStatus = "Importing from browser…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                BrowserCookieImporter.importClaudeSessionKey()
            }.value
            isImporting = false
            switch result {
            case .success(let cookie):
                sessionKey = cookie.sessionKey
                connectionStatus = "Imported from \(cookie.browser) — detecting organization…"
                connect()  // org blank → auto-resolves, then saves
            case .failure(let error):
                connectionStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func finishConnect(sessionKey sk: String, orgId resolvedOrg: String) {
        if ClaudeAIKeychain.save(sessionKey: sk, orgId: resolvedOrg) {
            claudeAISourceEnabled = true
            sessionKey = ""
            orgId = resolvedOrg
            isConnected = true
            connectionStatus = ""
            testResult = ""
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
        testResult = ""
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

// MARK: - Notifications tab

private struct NotificationsSettingsTab: View {
    @AppStorage("enableNotifications") private var enableNotifications = true
    @AppStorage("warningThresholdPercent") private var warningThresholdPercent = 80.0
    @AppStorage("criticalThresholdPercent") private var criticalThresholdPercent = 95.0

    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: $enableNotifications)
                Text("Posts a notification when session or weekly usage crosses the warning or critical threshold. One notification per threshold per reset window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Severity Thresholds") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Warning at")
                        Spacer()
                        Text("\(Int(warningThresholdPercent))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $warningThresholdPercent, in: 50...90, step: 5)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Critical at")
                        Spacer()
                        Text("\(Int(criticalThresholdPercent))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $criticalThresholdPercent, in: 60...100, step: 5)
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
                Button("Check for updates…") { appState.checkForUpdates() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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

// MARK: - About tab

private struct AboutSettingsTab: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private let githubURL = URL(string: "https://github.com/jewei/claude-meter")!

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 168, height: 168)
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

                    // Load the artwork directly from the asset catalog rather than
                    // `NSApplication.shared.applicationIconImage`, which returns the
                    // generic macOS placeholder for LSUIElement (agent) apps.
                    Image("AppLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                Text("Claude Meter")
                    .font(.system(size: 28, weight: .bold))

                Text("VERSION \(appVersion.uppercased())")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                    )

                VStack(spacing: 14) {
                    Link(destination: githubURL) {
                        HStack(spacing: 8) {
                            Image("GitHubMark")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                            Text("GitHub")
                                .font(.body.weight(.medium))
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)

                    Text("© JEWEI MAK")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .tracking(1)
                }
                .padding(.top, 4)

                Text("An independent community project. Not affiliated with or endorsed by Anthropic. \"Claude\" is a trademark of Anthropic.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
