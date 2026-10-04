import SwiftUI

/// The form for pasted Claude OAuth tokens: an access token, an optional refresh token, and
/// an optional expiry. Tokens stay hidden until the user shows them. Cancel discards the
/// draft.
struct ManualTokenForm: View {
    let isWorking: Bool
    let connect: (_ access: String, _ refresh: String?, _ expiry: Date?) async -> Void
    let cancel: () -> Void

    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var showsTokens = false
    @State private var hasExpiry = false
    @State private var expiry = Date().addingTimeInterval(8 * 3_600)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Paste tokens from a Claude login. Claude Meter keeps them in its own Keychain item."
            )
            .font(MeterFont.body(12, .semibold))
            .foregroundStyle(Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            TokenField(title: "Access token", text: $accessToken, isRevealed: showsTokens)
            TokenField(
                title: "Refresh token (optional)", text: $refreshToken, isRevealed: showsTokens)
            HStack(spacing: 10) {
                MeterSwitch(label: "Set an expiry", isOn: $hasExpiry)
                Text("Set an expiry")
                    .font(MeterFont.body(12, .bold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityHidden(true)
                if hasExpiry {
                    DatePicker(
                        "Expiry", selection: $expiry, displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                }
            }
            HStack(spacing: 10) {
                Button {
                    showsTokens.toggle()
                } label: {
                    Label(
                        showsTokens ? "Hide tokens" : "Show tokens",
                        systemImage: showsTokens ? "eye.slash" : "eye"
                    )
                    .font(MeterFont.body(12, .bold))
                    .foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28)
                }
                .buttonStyle(QuietButtonStyle())
                Spacer(minLength: 8)
                Button(action: cancel) {
                    ChunkyButtonLabel(title: "Cancel")
                }
                .buttonStyle(QuietButtonStyle(radius: 12))
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    Task {
                        await connect(
                            Self.cleaned(accessToken) ?? "", Self.cleaned(refreshToken),
                            hasExpiry ? expiry : nil)
                    }
                }
                .buttonStyle(RaisedButtonStyle())
                .fixedSize()
                .disabled(Self.cleaned(accessToken) == nil || isWorking)
            }
        }
        .padding(12)
        .background(shape.fill(Palette.popover))
        .overlay(shape.strokeBorder(Palette.cardBorder, lineWidth: 1))
    }

    /// The pasted text without surrounding spaces or line breaks, or nil when empty.
    static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
