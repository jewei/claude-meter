import AppKit
import MeterPlatform
import SwiftUI

/// The launch-at-login switch. macOS owns the state, so the row reads it when it appears,
/// after each change, and when the user comes back to the app or the window, for example
/// after approving the item in System Settings.
struct LaunchAtLoginRow: View {
    @State private var status = LoginItem.Status.disabled
    @State private var error: String?

    var body: some View {
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
                        .buttonStyle(QuietButtonStyle(radius: 12))
                        .accessibilityLabel("Open Login Items in System Settings")
                    }
                }
            }
            if let error {
                Text(error)
                    .font(MeterFont.body(11, .bold))
                    .foregroundStyle(Palette.energyEmptyInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { status = LoginItem.status }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in status = LoginItem.status }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            _ in status = LoginItem.status
        }
    }

    private var isOn: Binding<Bool> {
        Binding {
            status.isOn
        } set: { isOn in
            error = LoginItem.setEnabled(isOn)
            status = LoginItem.status
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
