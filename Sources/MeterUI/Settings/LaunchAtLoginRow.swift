import AppKit
import MeterApp
import MeterPlatform
import SwiftUI

/// The launch-at-login switch. macOS owns the state, so the row reads it when it appears,
/// after each change, and when the user comes back to the app or the window, for example
/// after approving the item in System Settings. An error stays until macOS reports the state
/// that the user chose, also across tabs and a closed window (``LaunchAtLoginState``).
struct LaunchAtLoginRow: View {
    let state: LaunchAtLoginState

    var body: some View {
        let status = state.status
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow(
                symbol: "power", tint: Palette.Tile.violet, title: "Launch at login",
                subtitle: "Start Claude Meter when you log in."
            ) {
                MeterSwitch(label: "Launch at login", isOn: isOn)
                    .disabled(status == .unavailable)
            }
            if let note = status.note {
                HStack(spacing: 8) {
                    if let symbol = status.noteSymbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Palette.energyLowInk)
                            .accessibilityHidden(true)
                    }
                    Text(note)
                        .font(MeterFont.body(12, .semibold))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if status == .requiresApproval {
                        Button {
                            LoginItem.openSystemSettings()
                        } label: {
                            ChunkyButtonLabel(title: "Open")
                        }
                        .buttonStyle(.chunky)
                        .accessibilityLabel("Open Login Items in System Settings")
                    }
                }
            }
            if let error = state.error.text {
                Text(error)
                    .font(MeterFont.body(11, .bold))
                    .foregroundStyle(Palette.energyEmptyInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { state.read() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in state.read() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            _ in state.read()
        }
    }

    private var isOn: Binding<Bool> {
        Binding {
            state.status.isOn
        } set: { isOn in
            state.choose(isOn)
        }
    }
}

extension LoginItem.Status {
    /// The symbol before the note: waiting for approval, or a warning when macOS cannot start
    /// this copy at all.
    var noteSymbol: String? {
        switch self {
        case .enabled, .disabled: nil
        case .requiresApproval: "hourglass"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }
}
