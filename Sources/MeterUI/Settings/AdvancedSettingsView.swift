import AppKit
import MeterApp
import MeterPlatform
import SwiftUI

/// Settings > Advanced: fetching and launch at login, updates, and diagnostics.
struct AdvancedSettingsView: View {
    let model: AppModel
    let launchAtLogin: LaunchAtLoginState

    @State private var showsDiagnostics = false

    var body: some View {
        @Bindable var store = model.settings
        SettingsPage(
            title: "Advanced", subtitle: "Set your routine and keep things running smoothly."
        ) {
            SectionHeading(text: "App")
            SettingsCard(spacing: 12) {
                SettingsRow(
                    symbol: "pause.fill", tint: Palette.Tile.cyan, title: "Fetch usage",
                    subtitle:
                        "Pause to stop all updates. The menu bar dims and keeps its last reading."
                ) {
                    MeterSwitch(
                        label: "Fetch usage",
                        isOn: Binding {
                            !store.settings.isPaused
                        } set: { isOn in
                            store.settings.isPaused = !isOn
                        })
                }
                CardDivider()
                LaunchAtLoginRow(state: launchAtLogin)
            }
            SectionHeading(text: "Updates")
            UpdatesCard(updater: model.updater)
            SectionHeading(text: "Diagnostics")
            SettingsCard(spacing: 12) {
                SettingsRow(
                    symbol: "waveform.path.ecg", tint: Palette.Tile.orange, title: "Diagnostics",
                    subtitle: "Inspect data sources and usage readings."
                ) {
                    Button {
                        showsDiagnostics = true
                    } label: {
                        ChunkyButtonLabel(title: "Open…", trailingSymbol: "chevron.right")
                    }
                    .buttonStyle(.chunky)
                    .accessibilityLabel("Open Diagnostics")
                }
                CardDivider()
                SettingsRow(
                    symbol: "doc.text", tint: Palette.Tile.slate, title: "Write a log file",
                    subtitle:
                        "Record redacted activity for bug reports. Turning this off deletes it."
                ) {
                    MeterSwitch(label: "Write a log file", isOn: $store.settings.writesLogFile)
                }
                if store.settings.writesLogFile {
                    HStack(spacing: 12) {
                        Button(action: showLogInFinder) {
                            ChunkyButtonLabel(title: "Show in Finder", symbol: "folder")
                        }
                        .buttonStyle(.chunky)
                        // The folder of this build: Debug builds log to "ClaudeMeter Debug".
                        Text(
                            (model.logFile.directory.path as NSString).abbreviatingWithTildeInPath
                        )
                        .font(MeterFont.body(12, .semibold))
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.logFile.directory.path)
                    }
                }
            }
        }
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticsSheet { await model.diagnostics() }
        }
    }

    /// Selects the log file in Finder, or opens its folder when the file is not written yet.
    private func showLogInFinder() {
        let log = model.logFile
        if !NSWorkspace.shared.selectFile(log.current.path, inFileViewerRootedAtPath: "") {
            NSWorkspace.shared.open(log.directory)
        }
    }
}
