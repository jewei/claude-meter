import MeterApp
import SwiftUI

/// The form for pasted Claude OAuth tokens: where they may come from, an access token, an
/// optional refresh token, and an optional expiry. Tokens stay hidden until the user shows
/// them.
///
/// Return connects. Cancel discards the draft and stops a Connect that is still running, so
/// nothing is saved after it. Escape cancels only while both token fields are empty, so a
/// stray key never loses pasted tokens.
struct ManualTokenForm: View {
    let isWorking: Bool
    let connect: (_ access: String, _ refresh: String?, _ expiry: Date?) async -> Void
    let cancel: () -> Void

    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var showsTokens = false
    @State private var hasExpiry = false
    @State private var expiry = Date().addingTimeInterval(8 * 3_600)
    @State private var connecting: Task<Void, Never>?

    private var isDraftEmpty: Bool {
        Self.cleaned(accessToken) == nil && Self.cleaned(refreshToken) == nil
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Paste tokens from a Claude login. Claude Meter keeps them in its own Keychain item."
            )
            .font(MeterFont.body(12, .semibold))
            .foregroundStyle(Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            sourceNote
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
            buttons
        }
        .padding(12)
        .background(shape.fill(Palette.popover))
        .overlay(shape.strokeBorder(Palette.cardBorder, lineWidth: 1))
    }

    /// Manual tokens must come from a separate login (`docs/providers/claude-oauth.md`).
    private var sourceNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.energyLowInk)
                .accessibilityHidden(true)
            Text(DataSourceText.manualTokensSource)
                .font(MeterFont.body(12, .bold))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var buttons: some View {
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
            Button {
                connecting?.cancel()
                connecting = nil
                cancel()
            } label: {
                ChunkyButtonLabel(title: "Cancel")
            }
            .buttonStyle(QuietButtonStyle(radius: 12))
            .keyboardShortcut(isDraftEmpty ? .cancelAction : nil)
            Button("Connect") {
                let access = Self.cleaned(accessToken) ?? ""
                let refresh = Self.cleaned(refreshToken)
                let expiry = hasExpiry ? expiry : nil
                connecting = Task { await connect(access, refresh, expiry) }
            }
            .buttonStyle(RaisedButtonStyle())
            .fixedSize()
            .keyboardShortcut(.defaultAction)
            .disabled(Self.cleaned(accessToken) == nil || isWorking)
        }
    }

    /// The pasted text without surrounding spaces or line breaks, or nil when empty.
    static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
