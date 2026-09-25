import AppKit
import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI

// MARK: - Shared card chrome

struct DataSourceCard<Content: View>: View {
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
                    .accessibilityLabel(title)
            }

            content()
                .padding(.leading, contentLeading)
        }
        .padding(16)
        .chunkyCard(radius: 18)
    }
}

// MARK: - Data tab

struct DataSettingsTab: View {
    let appState: AppState

    @AppStorage(AppSettings.oauthSourceEnabledKey) private var oauthSourceEnabled = true
    @AppStorage(AppSettings.oauthModeKey) private var oauthMode = ""
    @AppStorage(AppSettings.cursorSourceEnabledKey) private var cursorSourceEnabled = false
    @AppStorage(AppSettings.codexSourceEnabledKey) private var codexSourceEnabled = false
    @AppStorage(AppSettings.grokSourceEnabledKey) private var grokSourceEnabled = false

    @State private var cursorStatus = ""
    @State private var cursorStatusGeneration = 0
    @State private var cursorStatusTask: Task<Void, Never>?
    @State private var codexStatus = ""
    @State private var codexStatusGeneration = 0
    @State private var codexStatusTask: Task<Void, Never>?
    @State private var grokStatus = ""
    @State private var grokStatusGeneration = 0
    @State private var grokStatusTask: Task<Void, Never>?

    private var oauthSubtitle: String {
        guard !oauthMode.isEmpty else {
            return oauthSourceEnabled
                ? "Not connected — complete setup below."
                : "Not connected — enable this source to set it up."
        }
        return oauthSourceEnabled
            ? "Connected; reads credentials from Keychain."
            : "Connected; usage source paused."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Data Sources")
                        .font(PFont.display(26, .bold))
                        .foregroundStyle(Color.pfInk)
                    Text(
                        "Choose the providers that supply your usage data."
                    )
                    .font(PFont.body(13, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }

                DataSourceCard(
                    icon: "key.fill",
                    iconColor: Color(hex: "F4B400"),
                    title: "Claude OAuth",
                    subtitle: oauthSubtitle,
                    isEnabled: $oauthSourceEnabled
                ) {
                    OAuthConnectionSection(appState: appState)
                    if oauthSourceEnabled && oauthMode == "auto" {
                        ConfigDirAccountsSection(appState: appState)
                    }
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

                DataSourceCard(
                    icon: "sparkles",
                    iconColor: Color(hex: "49A3B0"),
                    title: "Codex",
                    subtitle: "Read subscription usage from your Codex sign-in.",
                    isEnabled: $codexSourceEnabled
                ) {
                    codexContent
                }

                DataSourceCard(
                    icon: "atom",
                    iconColor: Color(hex: "1C1C1E"),
                    title: "Grok",
                    subtitle: "Read Grok Build weekly credit usage (unofficial API; may break).",
                    isEnabled: $grokSourceEnabled
                ) {
                    grokContent
                }
            }
            .padding(20)
        }
        .onAppear {
            loadCursorStatus()
            loadCodexStatus()
            loadGrokStatus()
        }
        .onChange(of: oauthSourceEnabled) { _, _ in appState.providerEnablementDidChange() }

        .onChange(of: cursorSourceEnabled) { _, _ in
            loadCursorStatus()
            appState.providerEnablementDidChange()
        }
        .onChange(of: codexSourceEnabled) { _, _ in
            loadCodexStatus()
            appState.providerEnablementDidChange()
        }
        .onChange(of: grokSourceEnabled) { _, _ in
            loadGrokStatus()
            appState.providerEnablementDidChange()
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
            // SQLite and Keychain reads must stay off the main actor.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try CursorTokenStore.detect() }
            }.value
            let status: String
            switch result {
            case .success(let creds?):
                let plan = creds.membership.map { " · \($0)" } ?? ""
                let emailPart = creds.email.map { ": \(Self.maskedEmail($0))" } ?? ""
                status = "Connected\(emailPart)\(plan)"
            case .success(nil):
                status = "Cursor not detected — sign in to the Cursor app."
            case .failure(let error):
                status = DiagnosticsSanitizer.sanitize(error.localizedDescription)
            }
            guard !Task.isCancelled, generation == cursorStatusGeneration else { return }
            cursorStatus = status
        }
    }

    @ViewBuilder
    private var codexContent: some View {
        if codexSourceEnabled {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(
                        systemName: codexStatus.hasPrefix("Connected")
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(codexStatus.hasPrefix("Connected") ? .green : .secondary)
                    Text(codexStatus.isEmpty ? "Checking…" : codexStatus)
                }
                CodexHomesSection(appState: appState)
                ForEach(appState.codexAccounts) { reading in
                    if let error = reading.lastError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("\(reading.label): \(error)")
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func loadCodexStatus() {
        codexStatusTask?.cancel()
        guard codexSourceEnabled else {
            codexStatus = ""
            return
        }
        codexStatus = ""
        codexStatusGeneration += 1
        let generation = codexStatusGeneration
        codexStatusTask = Task {
            let status = await Task.detached(priority: .userInitiated) {
                do {
                    _ = try CodexOAuthCredentialsStore.load()
                    return "Connected to Codex"
                } catch CodexOAuthCredentialsError.apiKeyOnly {
                    return
                        "API-key sign-in has no subscription quota. Sign in with ChatGPT in Codex."
                } catch {
                    return CodexCLILocator.resolve() != nil
                        ? "Codex detected; checking sign-in during refresh."
                        : "Sign in with ChatGPT using `codex login`."
                }
            }.value
            guard !Task.isCancelled, generation == codexStatusGeneration else { return }
            codexStatus = DiagnosticsSanitizer.sanitize(status)
        }
    }

    @ViewBuilder
    private var grokContent: some View {
        if grokSourceEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(
                        systemName: grokStatus.hasPrefix("Connected")
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(grokStatus.hasPrefix("Connected") ? .green : .secondary)
                    Text(grokStatus.isEmpty ? "Checking…" : grokStatus)
                }
                if let err = appState.grokError {
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

    private func loadGrokStatus() {
        grokStatusTask?.cancel()
        guard grokSourceEnabled else {
            grokStatus = ""
            return
        }
        grokStatus = ""
        grokStatusGeneration += 1
        let generation = grokStatusGeneration
        grokStatusTask = Task {
            let status = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    let creds = try GrokAuthStore.load()
                    if let email = creds.email {
                        return "Connected as \(Self.maskedEmail(email))"
                    }
                    return "Connected via Grok Build CLI"
                } catch {
                    return (error as? LocalizedError)?.errorDescription
                        ?? "Grok Build CLI not signed in — run `grok login`."
                }
            }.value
            guard !Task.isCancelled, generation == grokStatusGeneration else { return }
            grokStatus = DiagnosticsSanitizer.sanitize(status)
        }
    }

    private nonisolated static func maskedEmail(_ email: String) -> String {
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
enum AccountTrackingPolicy {
    static func updating(
        disabledKeys: Set<String>,
        accountID: String,
        enabled: Bool
    ) -> Set<String> {
        var result = disabledKeys
        if enabled {
            result.remove(accountID)
        } else {
            result.insert(accountID)
        }
        return result
    }
}

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
                "Each config directory supplies separate Claude OAuth credentials. The menu bar uses your pinned account, or the account nearest its limit. The popover shows the other accounts."
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
        let isDefault = account.id == "claude"
        let display =
            (names[account.id]?.isEmpty == false)
            ? names[account.id]! : account.label.friendlyAccountLabel
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
                .accessibilityLabel("Track \(display)")
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
                disabledKeys = AccountTrackingPolicy.updating(
                    disabledKeys: disabledKeys,
                    accountID: key,
                    enabled: enabled)
                MeterSettings.disabledAccountKeys = Array(disabledKeys)
                appState.claudeConfigurationDidChange()
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
        MeterSettings.accountPlans = plans
    }

    /// Editable display name; blank clears the override (falls back to the default).
    private func nameBinding(for key: String) -> Binding<String> {
        Binding(
            get: { names[key] ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    names.removeValue(forKey: key)
                } else {
                    names[key] = newValue
                }
                MeterSettings.accountNames = names
            }
        )
    }

    private func reload() {
        disabledKeys = Set(MeterSettings.disabledAccountKeys)
        configuredDirs = MeterSettings.configuredConfigDirs
        plans = MeterSettings.accountPlans
        names = MeterSettings.accountNames
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
        panel.message =
            "Choose a Claude config directory (one containing settings.json or projects/)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ConfigDirDiscovery.isPlausibleConfigDir(url) else {
            addError =
                "That folder doesn't look like a Claude config dir (no settings.json or projects/)."
            return
        }
        addError = nil
        var dirs = MeterSettings.configuredConfigDirs
        if !dirs.contains(url.path) {
            dirs.append(url.path)
            MeterSettings.configuredConfigDirs = dirs
            appState.claudeConfigurationDidChange()
        }
        reload()
    }
}

private struct CodexHomesSection: View {
    let appState: AppState
    @State private var homes: [String] = []
    @State private var names: [String: String] = [:]
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(appState.codexConfiguration) { account in
                HStack(spacing: 12) {
                    RaisedTile(fill: avatarColorForID(account.id), size: 40, radius: 11) {
                        Text(accountLetter(account))
                            .font(PFont.display(17, .bold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        TextField(account.defaultName, text: nameBinding(for: account))
                            .textFieldStyle(.plain)
                            .font(PFont.display(15, .semibold))
                            .foregroundStyle(Color.pfInk)
                            .help("Display name shown in the popover")
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.system(size: 9, weight: .semibold))
                            Text(account.home.path)
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
                    Spacer()
                    if account.isImplicit {
                        Text("Default")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Remove") { remove(account) }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(12)
                .chunkyCard(fill: .pfPopover, radius: 16)
            }
            Button("Add Codex home…") { addHome() }
                .buttonStyle(.borderless)
            if let addError {
                Text(addError).foregroundStyle(.red)
            }
            Text("Each folder is a separate CODEX_HOME. Accounts keep independent quotas.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            homes = AppSettings.configuredCodexHomes
            names = AppSettings.codexAccountNames
        }
    }

    private func nameBinding(for account: CodexAccount) -> Binding<String> {
        Binding(
            get: { names[account.id] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    names.removeValue(forKey: account.id)
                } else {
                    names[account.id] = value
                }
                AppSettings.codexAccountNames = names
                appState.codexAccountNamesDidChange()
            })
    }

    private func accountLetter(_ account: CodexAccount) -> String {
        let name = names[account.id] ?? account.displayName
        return String(name.first(where: { $0.isLetter || $0.isNumber }) ?? Character("C"))
            .uppercased()
    }

    private func addHome() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a Codex home containing auth.json or config.toml."
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let url = selected.standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        guard
            fileManager.fileExists(atPath: url.appendingPathComponent("auth.json").path)
                || fileManager.fileExists(atPath: url.appendingPathComponent("config.toml").path)
        else {
            addError = "That folder does not look like a Codex home."
            return
        }
        addError = nil
        let existing = Set(appState.codexConfiguration.map(\.id))
        guard !existing.contains(url.path) else { return }
        homes.append(url.path)
        AppSettings.configuredCodexHomes = homes
        appState.codexConfigurationDidChange()
    }

    private func remove(_ account: CodexAccount) {
        homes.removeAll {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                == account.id
        }
        AppSettings.configuredCodexHomes = homes
        names.removeValue(forKey: account.id)
        AppSettings.codexAccountNames = names
        appState.codexConfigurationDidChange()
    }
}
