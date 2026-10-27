import AppKit
import MeterApp
import SwiftUI

/// Settings > Appearance > Alerts: one switch per alert, and how to turn notifications on
/// when macOS blocks them.
struct AlertsCard: View {
    let model: AppModel

    /// System Settings > Notifications.
    static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")

    var body: some View {
        @Bindable var store = model.settings
        let alerts = $store.settings.alerts
        SettingsCard(spacing: 12) {
            SettingsRow(
                symbol: "bell.badge", tint: Palette.Tile.gold, title: "Alerts",
                subtitle: "macOS notifications about your energy.")
            CardDivider()
            SettingsRow(
                symbol: "battery.25percent", tint: Palette.Tile.orange, title: "Low energy",
                subtitle: "A limit reaches the critical threshold."
            ) {
                MeterSwitch(label: "Low energy alerts", isOn: alerts.lowEnergy)
            }
            CardDivider()
            SettingsRow(
                symbol: "hourglass", tint: Palette.Tile.violet, title: "Runs out early",
                subtitle: "At this pace, a limit runs out before it resets."
            ) {
                MeterSwitch(label: "Run-out alerts", isOn: alerts.runOut)
            }
            CardDivider()
            SettingsRow(
                symbol: "bolt.fill", tint: Palette.Tile.green, title: "Refilled",
                subtitle: "A limit that ran low is full again after its reset."
            ) {
                MeterSwitch(label: "Refill alerts", isOn: alerts.refill)
            }
            if let notice = AlertPermissionText.notice(
                model.alerts.authorization, alerts: store.settings.alerts)
            {
                CardDivider()
                permissionNotice(notice)
            }
        }
    }

    private func permissionNotice(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(MeterFont.body(11, .semibold))
                .foregroundStyle(Palette.energyLowInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let url = Self.notificationSettingsURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Open System Settings")
                        .font(MeterFont.display(12, .semibold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
                .buttonStyle(QuietButtonStyle(radius: 10, surface: .chunky))
            }
        }
    }
}
