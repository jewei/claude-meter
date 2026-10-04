import MeterApp
import SwiftUI

/// Automatic update checks, the installed version, and "Check for Updates…".
struct UpdatesCard: View {
    let updater: any Updater

    var body: some View {
        let version = AppVersion.current
        let isUpdateAvailable = updater.isUpdateAvailable
        SettingsCard(spacing: 12) {
            SettingsRow(
                symbol: "arrow.clockwise", tint: Palette.Tile.sky,
                title: "Check for updates automatically",
                subtitle: UpdateCheckText.status(
                    version: version.version, build: version.build,
                    isUpdateAvailable: isUpdateAvailable),
                subtitleColor: isUpdateAvailable ? Palette.energyLowInk : Palette.heroFull.ink
            ) {
                MeterSwitch(
                    label: "Check for updates automatically",
                    isOn: Binding {
                        updater.automaticallyChecksForUpdates
                    } set: { isOn in
                        updater.automaticallyChecksForUpdates = isOn
                    })
            }
            CardDivider()
            HStack(spacing: 12) {
                Button {
                    updater.checkForUpdates()
                } label: {
                    ChunkyButtonLabel(title: "Check for Updates…", symbol: "arrow.clockwise")
                }
                .buttonStyle(QuietButtonStyle(radius: 12))
                .disabled(!updater.canCheckForUpdates)
                Text(UpdateCheckText.lastChecked(updater.lastCheckDate, now: Date()))
                    .font(MeterFont.body(12, .semibold))
                    .foregroundStyle(Palette.inkMuted)
                Spacer(minLength: 0)
            }
        }
    }
}
