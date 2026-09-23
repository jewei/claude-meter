import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI

struct AppearanceSettingsTab: View {
    @AppStorage(MeterSettings.cardStyleKey) private var cardStyle = "rings"
    @AppStorage(MeterSettings.progressionModeKey) private var progressionMode = "left"
    @AppStorage(MeterSettings.mainMeterProviderKey) private var mainMeterProvider = "claude"
    @AppStorage(MeterSettings.menuBarAccountKey) private var claudeMainMeterAccount = ""
    @AppStorage(MeterSettings.codexMainMeterAccountKey) private var codexMainMeterAccount = ""
    @AppStorage(MeterSettings.menuBarWindowKey) private var menuBarWindow = "nearest"

    @AppStorage("warningThresholdPercent") private var warningThresholdPercent = 80.0
    @AppStorage("criticalThresholdPercent") private var criticalThresholdPercent = 95.0

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
                    subtitle: "The provider that owns the hero and menu bar."
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
                    subtitle: "Choose which usage percentage appears in the menu bar."
                ) {
                    segmented(
                        $menuBarWindow,
                        [
                            ("nearest", "Nearest"), ("5h", "5h"), ("7d", "7d"),
                            ("both", "Both"),
                        ])
                }
                settingCard(
                    icon: "exclamationmark.circle", color: .pfEnergyLow,
                    title: "Severity thresholds",
                    subtitle: "Usage levels that change the menu bar and card colors."
                ) {
                    thresholdRow(
                        label: "Warning at", color: .pfEnergyLow,
                        value: $warningThresholdPercent, range: 50...90)
                    Divider().overlay(Color.pfCardBorder)
                    thresholdRow(
                        label: "Critical at", color: .pfEnergyEmpty,
                        value: $criticalThresholdPercent, range: 60...100)
                }
            }
            .padding(20)
        }
        .onAppear {
            let thresholds = MeterSettings.repairThresholdSettings()
            warningThresholdPercent = thresholds.warning
            criticalThresholdPercent = thresholds.critical
            MeterSettings.repairMenuBarWindow()
            reloadAccounts()
        }
        .onChange(of: warningThresholdPercent) { _, newWarning in
            if criticalThresholdPercent <= newWarning {
                criticalThresholdPercent = min(100, newWarning + 5)
            }
        }
        .onChange(of: criticalThresholdPercent) { _, newCritical in
            if newCritical <= warningThresholdPercent {
                criticalThresholdPercent = min(100, warningThresholdPercent + 5)
            }
        }
    }

    private func thresholdRow(
        label: String, color: Color, value: Binding<Double>, range: ClosedRange<Double>
    ) -> some View {
        let safeValue =
            value.wrappedValue.isFinite
            ? min(range.upperBound, max(range.lowerBound, value.wrappedValue))
            : range.lowerBound
        let safeBinding = Binding<Double>(
            get: {
                value.wrappedValue.isFinite
                    ? min(range.upperBound, max(range.lowerBound, value.wrappedValue))
                    : range.lowerBound
            },
            set: { value.wrappedValue = $0 })
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Circle().fill(color).frame(width: 12, height: 12)
                Text(label).font(PFont.display(16, .semibold)).foregroundStyle(Color.pfInk)
                Spacer()
                Text("\(Int(safeValue))%")
                    .font(PFont.display(14, .bold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(color.opacity(0.16)))
            }
            ColorSlider(
                value: safeBinding,
                range: range,
                step: 5,
                color: color,
                accessibilityName: label,
                accessibilityValueText: "\(Int(safeValue)) percent")
        }
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
        MeterSettings.accountName(forKey: account.id) ?? account.label.friendlyAccountLabel
    }

    private func reloadAccounts() {
        let configured = MeterSettings.configuredConfigDirs
        let disabled = Set(MeterSettings.disabledAccountKeys)
        Task.detached(priority: .userInitiated) {
            let found = ConfigDirDiscovery.discover(
                configuredDirs: configured, disabledKeys: disabled)
            await MainActor.run { self.accounts = found }
        }
    }
}
