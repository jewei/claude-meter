import MeterPlatform
import SwiftUI

/// The launch-at-login switch. macOS owns the state, so the row reads it each time it
/// appears and after each change.
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
                    Image(systemName: "hourglass")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.energyLow)
                        .accessibilityHidden(true)
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
