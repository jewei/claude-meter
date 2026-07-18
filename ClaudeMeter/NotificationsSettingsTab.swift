import ClaudeMeterCore
import SwiftUI

struct NotificationsSettingsTab: View {
    let appState: AppState
    @AppStorage("enableNotifications") private var enableNotifications = true
    @AppStorage("warningThresholdPercent") private var warningThresholdPercent = 80.0
    @AppStorage("criticalThresholdPercent") private var criticalThresholdPercent = 95.0
    @AppStorage(AppSettings.predictiveNotificationsEnabledKey)
    private var predictiveNotifications = false
    @AppStorage(AppSettings.attentionStopEnabledKey) private var attentionStop = false
    @AppStorage(AppSettings.attentionNotificationEnabledKey) private var attentionNotification =
        false
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
                    VStack(alignment: .leading, spacing: 12) {
                        attentionRow(
                            "Predict early depletion",
                            "Warn when the current pace may empty a limit before it refills.",
                            $predictiveNotifications)
                        SettingsHelperBox(
                            "Threshold alerts fire once per level and reset window. Predictive alerts are opt-in and require two consecutive fresh readings."
                        )
                    }
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
                        "Installs lightweight Stop / Notification / StopFailure hooks into each Claude Code account; turning these off removes them. Click an alert to return to its Ghostty, Terminal, iTerm2, or WezTerm tab when available; Warp brings the app forward. macOS may ask once for Automation access."
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

private struct SettingsHelperBox: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(PFont.body(12, .semibold))
            .foregroundStyle(Color.pfInkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.pfPopover))
    }
}
