import AppKit
import ClaudeMeterCore
import ServiceManagement
import SwiftUI
import WidgetKit

// MARK: - Root

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection = 0

    private static let tabs: [(icon: String, title: String)] = [
        ("cylinder.split.1x2", "Data"),
        ("paintpalette.fill", "Appearance"),
        ("bell", "Notifications"),
        ("slider.horizontal.3", "Advanced"),
        ("info.circle", "About"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Color.pfPopoverBorder)
            Group {
                switch selection {
                case 0: DataSettingsTab(appState: appState)
                case 1: AppearanceSettingsTab(appState: appState)
                case 2: NotificationsSettingsTab(appState: appState)
                case 3: AdvancedSettingsTab(appState: appState)
                default: AboutSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 640)
        .background(Color.pfPopover)
        .background(SettingsWindowAccessor())
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(Array(Self.tabs.enumerated()), id: \.offset) { index, tab in
                tabButton(index, tab.icon, tab.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private func tabButton(_ index: Int, _ icon: String, _ title: String) -> some View {
        let selected = selection == index
        return Button { selection = index } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                Text(title).font(PFont.body(12, .heavy))
            }
            .foregroundStyle(selected ? Color.pfHeroFullInk : Color.pfInkMuted)
            .frame(width: 96)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.pfHeroFullBG : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Window shim (floating level + title)

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.level = .floating
            view.window?.title = "Claude Meter — Settings"
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.title = "Claude Meter — Settings" }
    }
}

// MARK: - Shared card chrome

private struct DataSourceCard<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isEnabled: Bool
    var contentLeading: CGFloat = 48
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RaisedTile(fill: iconColor, size: 40, radius: 11) {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(PFont.display(16, .semibold))
                        .foregroundStyle(Color.pfInk)
                    Text(subtitle)
                        .font(PFont.body(12, .semibold))
                        .foregroundStyle(Color.pfInkMuted)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            content()
                .padding(.leading, contentLeading)
        }
        .padding(16)
        .chunkyCard(radius: 18)
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
                Text(
                    "Reads Claude Code's Keychain; refreshed tokens stay in memory for this session only."
                )
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
                        TextField(
                            "", text: $manualAccess,
                            prompt: Text("oidc-…").foregroundColor(.secondary))
                    } else {
                        SecureField(
                            "", text: $manualAccess,
                            prompt: Text("oidc-…").foregroundColor(.secondary))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                Button {
                    showAccessToken.toggle()
                } label: {
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
                        TextField(
                            "", text: $manualRefresh,
                            prompt: Text("Refresh token").foregroundColor(.secondary))
                    } else {
                        SecureField(
                            "", text: $manualRefresh,
                            prompt: Text("Refresh token").foregroundColor(.secondary))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
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
                    .controlSize(.small)
                    .disabled(
                        manualAccess.trimmingCharacters(in: .whitespaces).isEmpty
                            || manualRefresh.trimmingCharacters(in: .whitespaces).isEmpty)
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
        case "auto": state = .connectedAuto
        case "manual": state = OAuthKeychain.loadManual() != nil ? .connectedManual : .manualEntry
        default: state = OAuthKeychain.load() != nil ? .promptAuto : .promptNoAuto
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
                guard let creds = OAuthKeychain.loadManual() else {
                    throw URLError(.badServerResponse)
                }
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
        OAuthPipeline.clearCachedCredentials()
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
    @AppStorage(AppSettings.cursorSourceEnabledKey) private var cursorSourceEnabled = false

    @State private var cursorStatus = ""
    @State private var cursorStatusGeneration = 0
    @State private var cursorStatusTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data Sources")
                        .font(PFont.display(26, .bold))
                        .foregroundStyle(Color.pfInk)
                    Text(
                        "Configure how Claude Meter collects your usage data. Enable multiple sources for redundancy."
                    )
                    .font(PFont.body(13, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }

                DataSourceCard(
                    icon: "terminal",
                    iconColor: Color(hex: "4FC51C"),
                    title: "Statusline Bridge",
                    subtitle: "Checks your statusline once per minute.",
                    isEnabled: $statuslineSourceEnabled,
                    contentLeading: 0
                ) {
                    if statuslineSourceEnabled {
                        ConfigDirAccountsSection(appState: appState)
                    }
                }

                DataSourceCard(
                    icon: "key.fill",
                    iconColor: Color(hex: "F4B400"),
                    title: "Claude Code OAuth",
                    subtitle: "Use OAuth credentials from Keychain.",
                    isEnabled: $oauthSourceEnabled
                ) {
                    OAuthConnectionSection(appState: appState)
                }

                DataSourceCard(
                    icon: "cursorarrow.rays",
                    iconColor: Color(hex: "2DD4BF"),
                    title: "Cursor",
                    subtitle: "Read Cursor billing-period usage (unofficial API; may break).",
                    isEnabled: $cursorSourceEnabled
                ) {
                    cursorContent
                }
            }
            .padding(20)
        }
        .onAppear {
            loadCursorStatus()
        }
        .onChange(of: statuslineSourceEnabled) { _, _ in appState.scheduleRebuildPipeline() }
        .onChange(of: oauthSourceEnabled) { _, _ in appState.scheduleRebuildPipeline() }
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
                    Image(
                        systemName: cursorStatus.hasPrefix("Connected")
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
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
}

// MARK: - Config-dir accounts (multiple CLAUDE_CONFIG_DIR accounts)

/// Lists discovered Claude config dirs (one per account), letting the user disable
/// non-default ones and add custom paths. Rate limits are per-account, so the meter
/// keeps them separate; the menu bar follows the most recently used account.
private struct ConfigDirAccountsSection: View {
    let appState: AppState

    @State private var accounts: [AccountConfig] = []
    @State private var disabledKeys: Set<String> = []
    @State private var configuredDirs: [String] = []
    @State private var addError: String?
    @State private var plans: [String: String] = [:]
    @State private var names: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Hide the list while there's only the default account and nothing custom.
            if accounts.count > 1 || !configuredDirs.isEmpty {
                ForEach(accounts) { account in
                    accountRow(account)
                }
            }

            Button {
                addCustomDir()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 13, weight: .bold))
                    Text("Add config directory…").font(PFont.display(13, .semibold))
                }
                .foregroundStyle(Color.pfInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .chunkyCard(radius: 12)
            }
            .buttonStyle(.plain)

            if let addError {
                Text(addError)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "Each account runs via its own `CLAUDE_CONFIG_DIR`, so every login keeps a separate rate limit. The menu bar follows your most recently used account — the rest live in the popover."
            )
            .font(PFont.body(12, .semibold))
            .foregroundStyle(Color.pfInkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.pfPopover))
        }
        .padding(.top, 2)
        .onAppear { reload() }
    }

    private func accountRow(_ account: AccountConfig) -> some View {
        let isDefault = account.id == StatuslineBridge.defaultAccountKey
        let display = (names[account.id]?.isEmpty == false) ? names[account.id]! : account.label.friendlyAccountLabel
        let letter = String(
            display.drop(while: { !$0.isLetter && !$0.isNumber }).first ?? Character("C")
        ).uppercased()
        return HStack(spacing: 12) {
            RaisedTile(fill: avatarColorForID(account.id), size: 40, radius: 11) {
                Text(letter)
                    .font(PFont.display(17, .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 5) {
                TextField(account.label.friendlyAccountLabel, text: nameBinding(for: account.id))
                    .textFieldStyle(.plain)
                    .font(PFont.display(15, .semibold))
                    .foregroundStyle(Color.pfInk)
                    .help("Display name shown in the popover")
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 9, weight: .semibold))
                    Text(account.configDir.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Color.pfInkMuted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.pfTrack.opacity(0.7)))
            }
            Spacer(minLength: 8)
            planMenu(for: account.id)
            Toggle("", isOn: enabledBinding(for: account.id))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .disabled(isDefault)
                .help(isDefault ? "The default account is always tracked" : "Track this account")
        }
        .padding(12)
        .chunkyCard(fill: .pfPopover, radius: 16)
    }

    private func enabledBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { !disabledKeys.contains(key) },
            set: { enabled in
                if enabled {
                    disabledKeys.remove(key)
                } else {
                    disabledKeys.insert(key)
                    // A disabled account is no longer tracked, so a menu-bar pin to it
                    // would silently fall back to nearest-limit. Clear the pin so the
                    // Appearance picker label matches the menu bar's behavior.
                    if AppGroupConfig.menuBarAccount == key {
                        UserDefaults.standard.removeObject(forKey: AppGroupConfig.menuBarAccountKey)
                        AppGroupConfig.syncDisplaySettings()
                    }
                }
                AppGroupConfig.disabledAccountKeys = Array(disabledKeys)
                appState.scheduleRebuildPipeline()
            }
        )
    }

    /// Plan is OAuth-only and single-slot, so the user tags each account's badge
    /// by hand here; the popover reads it back per render.
    private func planMenu(for key: String) -> some View {
        Menu {
            Button("No badge") { setPlan(key, nil) }
            Divider()
            ForEach(["Free", "Pro", "Max", "Team"], id: \.self) { plan in
                Button(plan) { setPlan(key, plan) }
            }
        } label: {
            if let plan = plans[key], !plan.isEmpty {
                PlanBadge(plan: plan)
            } else {
                HStack(spacing: 2) {
                    Text("Set plan")
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func setPlan(_ key: String, _ plan: String?) {
        if let plan, !plan.isEmpty {
            plans[key] = plan
        } else {
            plans.removeValue(forKey: key)
        }
        AppGroupConfig.accountPlans = plans
    }

    /// Editable display name; blank clears the override (falls back to the default).
    private func nameBinding(for key: String) -> Binding<String> {
        Binding(
            get: { names[key] ?? "" },
            set: { newValue in
                if newValue.isEmpty { names.removeValue(forKey: key) } else { names[key] = newValue }
                AppGroupConfig.accountNames = names
            }
        )
    }

    private func reload() {
        disabledKeys = Set(AppGroupConfig.disabledAccountKeys)
        configuredDirs = AppGroupConfig.configuredConfigDirs
        plans = AppGroupConfig.accountPlans
        names = AppGroupConfig.accountNames
        let configured = configuredDirs
        Task.detached(priority: .userInitiated) {
            // Pass no disabled filter so disabled accounts still appear (and can be
            // re-enabled) in the list.
            let found = ConfigDirDiscovery.discover(configuredDirs: configured, disabledKeys: [])
            await MainActor.run { self.accounts = found }
        }
    }

    private func addCustomDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a Claude config directory (one containing settings.json or projects/)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ConfigDirDiscovery.isPlausibleConfigDir(url) else {
            addError =
                "That folder doesn't look like a Claude config dir (no settings.json or projects/)."
            return
        }
        addError = nil
        var dirs = AppGroupConfig.configuredConfigDirs
        if !dirs.contains(url.path) {
            dirs.append(url.path)
            AppGroupConfig.configuredConfigDirs = dirs
            appState.scheduleRebuildPipeline()
        }
        reload()
    }
}

// MARK: - Appearance tab

private struct AppearanceSettingsTab: View {
    let appState: AppState

    @AppStorage(AppGroupConfig.cardStyleKey) private var cardStyle = "rings"
    @AppStorage(AppGroupConfig.progressionModeKey) private var progressionMode = "left"
    @AppStorage(AppGroupConfig.menuBarAccountKey) private var menuBarAccount = ""
    @AppStorage(AppGroupConfig.menuBarWindowKey) private var menuBarWindow = "nearest"

    @State private var accounts: [AccountConfig] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Appearance")
                    .font(PFont.display(26, .bold))
                    .foregroundStyle(Color.pfInk)
                    .padding(.horizontal, 4)

                settingCard(
                    icon: "chart.bar.xaxis", color: Color(hex: "C77DFF"),
                    title: "Account cards", subtitle: "How each account's usage is drawn."
                ) {
                    segmented($cardStyle, [("rings", "Rings"), ("bars", "Energy bars")])
                }

                settingCard(
                    icon: "arrow.left.arrow.right", color: Color(hex: "25B6F0"),
                    title: "Show", subtitle: "Energy remaining, or usage so far."
                ) {
                    segmented($progressionMode, [("left", "Energy left"), ("used", "Usage")])
                }

                settingCard(
                    icon: "menubar.rectangle", color: Color(hex: "FF9D0A"),
                    title: "Menu bar follows",
                    subtitle: "Which account the menu-bar percentage tracks."
                ) {
                    menuBarPicker
                }

                settingCard(
                    icon: "gauge.with.dots.needle.bottom.50percent", color: Color(hex: "4FC51C"),
                    title: "Menu bar shows",
                    subtitle: "Which window the percentage reflects."
                ) {
                    segmented(
                        $menuBarWindow,
                        [("nearest", "Nearest"), ("5h", "5h"), ("7d", "7d"), ("both", "Both")])
                }
            }
            .padding(20)
        }
        .onAppear { reloadAccounts() }
        .onChange(of: cardStyle) { _, _ in AppGroupConfig.syncDisplaySettings() }
        .onChange(of: progressionMode) { _, _ in
            AppGroupConfig.syncDisplaySettings()
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: menuBarAccount) { _, _ in AppGroupConfig.syncDisplaySettings() }
        .onChange(of: menuBarWindow) { _, _ in AppGroupConfig.syncDisplaySettings() }
    }

    @ViewBuilder
    private func settingCard<Control: View>(
        icon: String, color: Color, title: String, subtitle: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RaisedTile(fill: color, size: 40, radius: 11) {
                    Image(systemName: icon).font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(PFont.display(16, .semibold)).foregroundStyle(Color.pfInk)
                    Text(subtitle).font(PFont.body(12, .semibold)).foregroundStyle(Color.pfInkMuted)
                }
                Spacer(minLength: 8)
            }
            control()
        }
        .padding(16)
        .chunkyCard(radius: 18)
    }

    private func segmented(_ selection: Binding<String>, _ options: [(String, String)]) -> some View
    {
        HStack(spacing: 8) {
            ForEach(options, id: \.0) { value, label in
                let selected = selection.wrappedValue == value
                Button { selection.wrappedValue = value } label: {
                    Text(label)
                        .font(PFont.display(13, .semibold))
                        .foregroundStyle(selected ? Color.pfHeroFullInk : Color.pfInkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selected ? Color.pfHeroFullBG : Color.pfPopover)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(
                                            selected ? Color.pfHeroFullBorder : Color.pfCardBorder,
                                            lineWidth: 1.5))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var menuBarPicker: some View {
        Menu {
            Button("Nearest limit") { menuBarAccount = "" }
            if !accounts.isEmpty {
                Divider()
                ForEach(accounts) { account in
                    Button(displayName(account)) { menuBarAccount = account.id }
                }
            }
        } label: {
            HStack {
                Text(currentMenuBarLabel)
                    .font(PFont.display(14, .semibold)).foregroundStyle(Color.pfInk)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.pfInkMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.pfPopover)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.pfCardBorder, lineWidth: 1.5))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var currentMenuBarLabel: String {
        if menuBarAccount.isEmpty || menuBarAccount == "nearest" { return "Nearest limit" }
        if let acc = accounts.first(where: { $0.id == menuBarAccount }) { return displayName(acc) }
        return "Nearest limit"
    }

    private func displayName(_ account: AccountConfig) -> String {
        AppGroupConfig.accountName(forKey: account.id) ?? account.label.friendlyAccountLabel
    }

    private func reloadAccounts() {
        let configured = AppGroupConfig.configuredConfigDirs
        // Exclude disabled accounts — they aren't tracked, so they can't be pinned.
        let disabled = Set(AppGroupConfig.disabledAccountKeys)
        Task.detached(priority: .userInitiated) {
            let found = ConfigDirDiscovery.discover(
                configuredDirs: configured, disabledKeys: disabled)
            await MainActor.run { self.accounts = found }
        }
    }
}

// MARK: - Notifications tab

/// Shared tinted helper box used in the Settings cards. Accepts markdown
/// (e.g. `` `CLAUDE_CONFIG_DIR` `` renders monospace).
private struct SettingsHelperBox: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(PFont.body(12, .semibold))
            .foregroundStyle(Color.pfInkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.pfPopover))
    }
}

private struct NotificationsSettingsTab: View {
    let appState: AppState
    @AppStorage("enableNotifications") private var enableNotifications = true
    @AppStorage("warningThresholdPercent") private var warningThresholdPercent = 80.0
    @AppStorage("criticalThresholdPercent") private var criticalThresholdPercent = 95.0
    @AppStorage(AppSettings.attentionStopEnabledKey) private var attentionStop = false
    @AppStorage(AppSettings.attentionNotificationEnabledKey) private var attentionNotification = false
    @AppStorage(AppSettings.attentionLimitHitEnabledKey) private var attentionLimitHit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DataSourceCard(
                    icon: "bell.fill",
                    iconColor: Color(hex: "4FC51C"),
                    title: "Enable notifications",
                    subtitle: "Get a heads-up before you hit a wall.",
                    isEnabled: $enableNotifications,
                    contentLeading: 0
                ) {
                    SettingsHelperBox(
                        "Posts a notification when session or weekly usage crosses the warning or critical threshold — one alert per threshold, per reset window."
                    )
                }

                Text("Claude Attention")
                    .font(PFont.display(26, .bold))
                    .foregroundStyle(Color.pfInk)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 14) {
                    attentionRow(
                        "Notify when Claude finishes a turn",
                        "A native notification when a session is done and waiting on you.",
                        $attentionStop)
                    Divider().overlay(Color.pfCardBorder)
                    attentionRow(
                        "Notify when Claude needs permission",
                        "Covers permission prompts and idle waits.",
                        $attentionNotification)
                    Divider().overlay(Color.pfCardBorder)
                    attentionRow(
                        "Notify when Claude hits a limit",
                        "Ground-truth alert the moment a turn is blocked by a rate limit or billing issue — and the meter re-polls immediately.",
                        $attentionLimitHit)
                    SettingsHelperBox(
                        "Installs lightweight Stop / Notification / StopFailure hooks into each Claude Code account; turning these off removes them. Sound, Focus, and history are handled by macOS — tune them in System Settings → Notifications → Claude Meter."
                    )
                }
                .padding(16)
                .chunkyCard(radius: 18)
                .onChange(of: attentionStop) { _, _ in appState.attentionSettingsChanged() }
                .onChange(of: attentionNotification) { _, _ in appState.attentionSettingsChanged() }
                .onChange(of: attentionLimitHit) { _, _ in appState.attentionSettingsChanged() }

                Text("Severity Thresholds")
                    .font(PFont.display(26, .bold))
                    .foregroundStyle(Color.pfInk)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 16) {
                    thresholdRow(
                        label: "Warning at", color: .pfEnergyLow,
                        value: $warningThresholdPercent, range: 50...90)
                    Divider().overlay(Color.pfCardBorder)
                    thresholdRow(
                        label: "Critical at", color: .pfEnergyEmpty,
                        value: $criticalThresholdPercent, range: 60...100)
                    SettingsHelperBox(
                        "Threshold changes apply immediately — to both the menu bar display and your notifications."
                    )
                }
                .padding(16)
                .chunkyCard(radius: 18)
            }
            .padding(20)
        }
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

    private func attentionRow(_ title: String, _ subtitle: String, _ isOn: Binding<Bool>)
        -> some View
    {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PFont.display(15, .semibold)).foregroundStyle(Color.pfInk)
                Text(subtitle).font(PFont.body(12, .regular)).foregroundStyle(Color.pfInkMuted)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }

    private func thresholdRow(
        label: String, color: Color, value: Binding<Double>, range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Circle().fill(color).frame(width: 12, height: 12)
                Text(label).font(PFont.display(16, .semibold)).foregroundStyle(Color.pfInk)
                Spacer()
                Text("\(Int(value.wrappedValue))%")
                    .font(PFont.display(14, .bold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(color.opacity(0.16)))
            }
            ColorSlider(value: value, range: range, step: 5, color: color)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeading("App")
                HStack(spacing: 12) {
                    RaisedTile(fill: Color(hex: "C77DFF"), size: 40, radius: 11) {
                        Image(systemName: "power").font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    cardText("Launch at login", "Start Claude Meter when you log in.")
                    Spacer(minLength: 8)
                    Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                }
                .padding(16).chunkyCard(radius: 18)

                sectionHeading("Updates")
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        RaisedTile(fill: Color(hex: "25B6F0"), size: 40, radius: 11) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check for updates automatically")
                                .font(PFont.display(16, .semibold)).foregroundStyle(Color.pfInk)
                            Text(updateStatus).font(PFont.body(12, .bold))
                                .foregroundStyle(updateStatusColor)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: $automaticallyCheckForUpdates).toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Divider().overlay(Color.pfCardBorder)
                    HStack(spacing: 12) {
                        Button { appState.checkForUpdates() } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                                Text("Check for updates…").font(PFont.display(13, .semibold))
                            }
                            .foregroundStyle(Color.pfInk).padding(.horizontal, 14).padding(.vertical, 9)
                            .chunkyCard(radius: 12)
                        }
                        .buttonStyle(.plain)
                        if let last = lastCheckedText {
                            Text(last).font(PFont.body(12, .semibold)).foregroundStyle(Color.pfInkMuted)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(16).chunkyCard(radius: 18)

                sectionHeading("Diagnostics")
                HStack(spacing: 12) {
                    RaisedTile(fill: Color(hex: "FF9D0A"), size: 40, radius: 11) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    cardText("Diagnostics", "Inspect logs, data sources & raw limits.")
                    Spacer(minLength: 8)
                    Button { showingDiagnostics = true } label: {
                        HStack(spacing: 6) {
                            Text("Open Diagnostics…").font(PFont.display(13, .semibold))
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(Color.pfInk).padding(.horizontal, 14).padding(.vertical, 9)
                        .chunkyCard(radius: 12)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16).chunkyCard(radius: 18)
            }
            .padding(20)
        }
        .onAppear { syncLaunchAtLoginFromSystem() }
        .onChange(of: launchAtLogin) { _, newValue in applyLaunchAtLogin(newValue) }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView()
                .environmentObject(appState)
                .frame(minWidth: 480, minHeight: 380)
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(PFont.display(22, .bold))
            .foregroundStyle(Color.pfInk)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cardText(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(PFont.display(16, .semibold)).foregroundStyle(Color.pfInk)
            Text(subtitle).font(PFont.body(12, .semibold)).foregroundStyle(Color.pfInkMuted)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var updateStatus: String {
        appState.updateAvailable ? "Update available — click to install" : "Up to date · v\(appVersion) ✓"
    }

    private var updateStatusColor: Color {
        appState.updateAvailable ? .pfEnergyLow : .pfHeroFullInk
    }

    /// Sparkle persists the last automatic-check time; show it when available.
    private var lastCheckedText: String? {
        guard let date = UserDefaults.standard.object(forKey: "SULastCheckTime") as? Date
        else { return nil }
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "Last checked just now" }
        if elapsed < 3600 { return "Last checked \(elapsed / 60)m ago" }
        if elapsed < 86400 { return "Last checked \(elapsed / 3600)h ago" }
        return "Last checked \(elapsed / 86400)d ago"
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
        VStack(spacing: 18) {
            // Green bolt mark with a soft green glow — the app's playful identity.
            RaisedTile(fill: .pfEnergyFull, size: 104, radius: 26) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 54, weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "FFE38A"), Color(hex: "FF9D0A")],
                            startPoint: .top, endPoint: .bottom))
            }
            .shadow(color: Color.pfEnergyFull.opacity(0.5), radius: 18, y: 6)
            .padding(.top, 4)

            Text("Claude Meter")
                .font(PFont.display(28, .bold))
                .foregroundStyle(Color.pfInk)

            Text("VERSION \(appVersion.uppercased())")
                .font(PFont.body(11, .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.pfHeroFullInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.pfHeroFullBG))

            Link(destination: githubURL) {
                HStack(spacing: 10) {
                    Image("GitHubMark")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Text("View on GitHub")
                        .font(PFont.display(15, .semibold))
                }
                .foregroundStyle(Color.pfInk)
                .padding(.horizontal, 28)
                .padding(.vertical, 13)
                .chunkyCard(radius: 16)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            Rectangle()
                .fill(Color.pfCardBorder)
                .frame(height: 1)
                .padding(.horizontal, 2)
                .padding(.vertical, 4)

            Text("© JEWEI MAK")
                .font(PFont.body(12, .heavy))
                .tracking(1.0)
                .foregroundStyle(Color.pfInkMuted)

            Text(
                "An independent community project. Not affiliated with or endorsed by Anthropic. \u{201C}Claude\u{201D} is a trademark of Anthropic."
            )
            .font(PFont.body(12, .semibold))
            .foregroundStyle(Color.pfInkMuted.opacity(0.85))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
        }
        .padding(28)
        .frame(maxWidth: 470)
        .chunkyCard(radius: 22)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
