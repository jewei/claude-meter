import MeterApp
import SwiftUI

/// Automatic update checks, the installed version, and "Check for Updates…". The last-check
/// age renders again every minute while the card is on screen. A build that cannot update
/// itself shows only a note.
struct UpdatesCard: View {
    let updater: any Updater

    var body: some View {
        let version = AppVersion.current
        let status = UpdateCheckText.statusLine(
            version: version.version, build: version.build,
            isUpdateAvailable: updater.isUpdateAvailable, canUpdate: updater.isAvailable)
        if updater.isAvailable {
            controls(status: status)
        } else {
            SettingsCard(spacing: 12) {
                SettingsRow(
                    symbol: "arrow.clockwise", tint: Palette.Tile.sky, title: "Updates",
                    subtitle: status.text, subtitleColor: status.tone.color
                ) {
                    EmptyView()
                }
            }
        }
    }

    private func controls(status: (text: String, tone: UpdateCheckText.Tone)) -> some View {
        SettingsCard(spacing: 12) {
            SettingsRow(
                symbol: "arrow.clockwise", tint: Palette.Tile.sky,
                title: "Check for updates automatically", subtitle: status.text,
                subtitleColor: status.tone.color
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
                .buttonStyle(.chunky)
                .disabled(!updater.canCheckForUpdates)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(UpdateCheckText.lastChecked(updater.lastCheckDate, now: context.date))
                        .font(MeterFont.body(12, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkMuted)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

extension UpdateCheckText.Tone {
    var color: Color {
        switch self {
        case .attention: Palette.energyLowInk
        case .current: Palette.heroFull.ink
        case .neutral: Palette.inkMuted
        }
    }
}
