import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI
import WidgetKit

struct AppearanceSettingsTab: View {
    @ObservedObject var appState: AppState

    @AppStorage(AppGroupConfig.cardStyleKey) private var cardStyle = "rings"
    @AppStorage(AppGroupConfig.progressionModeKey) private var progressionMode = "left"
    @AppStorage(AppGroupConfig.mainMeterProviderKey) private var mainMeterProvider = "claude"
    @AppStorage(AppGroupConfig.menuBarAccountKey) private var claudeMainMeterAccount = ""
    @AppStorage(AppGroupConfig.codexMainMeterAccountKey) private var codexMainMeterAccount = ""
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
                    icon: "bolt.circle.fill", color: Color(hex: "4FC51C"),
                    title: "Main meter",
                    subtitle: "The provider that owns the hero, menu bar, widget, and quota alerts."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        segmented(
                            $mainMeterProvider,
                            [("claude", "Claude"), ("codex", "Codex")])
                        if selectedProvider == .codex && !AppSettings.codexSourceEnabled {
                            Text("Turn on Codex in Data settings to start this meter.")
                                .font(PFont.body(11, .semibold))
                                .foregroundStyle(Color.pfEnergyLow)
                        }
                    }
                }

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
                    title: "Main meter follows",
                    subtitle:
                        "Which \(selectedProvider.displayName) account the primary meter tracks."
                ) {
                    menuBarPicker
                }

                settingCard(
                    icon: "gauge.with.dots.needle.bottom.50percent", color: Color(hex: "4FC51C"),
                    title: "Main meter shows",
                    subtitle: "Which window the menu-bar percentage reflects."
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
        .onChange(of: mainMeterProvider) { _, _ in mainMeterSettingChanged() }
        .onChange(of: claudeMainMeterAccount) { _, _ in mainMeterSettingChanged() }
        .onChange(of: codexMainMeterAccount) { _, _ in mainMeterSettingChanged() }
        .onChange(of: menuBarWindow) { _, _ in mainMeterDisplaySettingChanged() }
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
                Button {
                    selection.wrappedValue = value
                } label: {
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

    private var selectedProvider: MainMeterProvider {
        MainMeterProvider(rawValue: mainMeterProvider) ?? .claude
    }

    private var selectedAccount: Binding<String> {
        selectedProvider == .claude ? $claudeMainMeterAccount : $codexMainMeterAccount
    }

    private var menuBarPicker: some View {
        Menu {
            Button("Nearest limit") { selectedAccount.wrappedValue = "" }
            if !mainMeterAccounts.isEmpty {
                Divider()
                ForEach(mainMeterAccounts, id: \.id) { account in
                    Button(account.label) { selectedAccount.wrappedValue = account.id }
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
        let selection = selectedAccount.wrappedValue
        if selection.isEmpty || selection == "nearest" { return "Nearest limit" }
        return mainMeterAccounts.first(where: { $0.id == selection })?.label
            ?? "Selected account unavailable"
    }

    private var mainMeterAccounts: [(id: String, label: String)] {
        switch selectedProvider {
        case .claude:
            return accounts.map { ($0.id, displayName($0)) }
        case .codex:
            return AppSettings.codexAccounts().map { ($0.id, $0.displayName) }
        }
    }

    private func displayName(_ account: AccountConfig) -> String {
        AppGroupConfig.accountName(forKey: account.id) ?? account.label.friendlyAccountLabel
    }

    private func mainMeterSettingChanged() {
        AppGroupConfig.syncDisplaySettings()
        appState.mainMeterSelectionChanged()
    }

    private func mainMeterDisplaySettingChanged() {
        AppGroupConfig.syncDisplaySettings()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func reloadAccounts() {
        let configured = AppGroupConfig.configuredConfigDirs
        let disabled = Set(AppGroupConfig.disabledAccountKeys)
        Task.detached(priority: .userInitiated) {
            let found = ConfigDirDiscovery.discover(
                configuredDirs: configured, disabledKeys: disabled)
            await MainActor.run { self.accounts = found }
        }
    }
}
