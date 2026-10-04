import MeterApp
import SwiftUI

/// The form for pasted Claude OAuth tokens: what Claude Meter does with them, where they may
/// come from, an access token, an optional refresh token, and an optional expiry. Tokens stay
/// hidden until the user shows them.
///
/// The draft rules are in ``ManualTokenDraft``. Return in a token field connects; Connect is
/// not the window's default button, so Return in another field of the page, such as a folder
/// name, never connects. Cancel discards the draft and stops a Connect that is still running,
/// so nothing is saved after it. Escape cancels while the draft is empty and no newer question
/// is open (``CancelShortcuts``).
struct ManualTokenForm: View {
    let isWorking: Bool
    let connect: (_ access: String, _ refresh: String?, _ expiry: Date?) async -> Void
    let cancel: () -> Void

    @State private var draft = ManualTokenDraft(now: Date())
    @State private var showsTokens = false
    @State private var connecting: Task<Void, Never>?

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
            Group {
                TokenField(
                    title: "Access token", text: $draft.accessToken, isRevealed: showsTokens)
                TokenField(
                    title: "Refresh token (optional)", text: $draft.refreshToken,
                    isRevealed: showsTokens)
            }
            .onSubmit(submit)
            HStack(spacing: 10) {
                MeterSwitch(label: "Set an expiry", isOn: $draft.hasExpiry)
                Text("Set an expiry")
                    .font(MeterFont.body(12, .bold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityHidden(true)
                if draft.hasExpiry {
                    DatePicker(
                        "Expiry", selection: $draft.expiry,
                        displayedComponents: [.date, .hourAndMinute]
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
            .buttonStyle(.chunky)
            .cancelShortcut(isEnabled: draft.escapeCancels)
            Button("Connect", action: submit)
                .buttonStyle(RaisedButtonStyle())
                .fixedSize()
                .disabled(!draft.canConnect(isWorking: isWorking))
        }
    }

    private func submit() {
        guard draft.canConnect(isWorking: isWorking), let submission = draft.submission else {
            return
        }
        connecting = Task {
            await connect(submission.accessToken, submission.refreshToken, submission.expiresAt)
        }
    }
}
