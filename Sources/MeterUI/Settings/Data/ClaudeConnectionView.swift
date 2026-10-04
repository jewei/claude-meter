import MeterApp
import MeterDomain
import SwiftUI

/// The Claude connection: both logins' states and the actions for the current connection.
///
/// "Connect automatically" asks for Keychain consent first when the user has not given it.
/// "Enter tokens manually" opens a form whose Cancel discards the draft and keeps the stored
/// credentials.
struct ClaudeConnectionView: View {
    /// What the view shows, read from ``ClaudeSettingsModel``.
    struct Snapshot: Equatable {
        var connection: ClaudeSettings.Connection
        var automaticStatus: SignInStatus?
        var manualStatus: SignInStatus?
        var isWorking = false
        var message: String?
        var needsKeychainConsent = false
    }

    struct Actions {
        var connectAutomatically: () async -> Void
        /// Returns true when the tokens were verified and saved.
        var connectManually: (_ access: String, _ refresh: String?, _ expiry: Date?) async -> Bool
        var disconnect: () async -> Void
    }

    let snapshot: Snapshot
    let actions: Actions
    /// Starts with the token form open. For previews and tests.
    var startsWithForm = false

    @State private var showsConsent = false
    @State private var showsForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SignInStatusLine(
                    status: DataSourceText.claudeCode(snapshot.automaticStatus),
                    label: "Automatic")
                SignInStatusLine(
                    status: DataSourceText.manualTokens(snapshot.manualStatus), label: "Manual")
            }
            if showsForm || startsWithForm {
                ManualTokenForm(isWorking: snapshot.isWorking) { access, refresh, expiry in
                    if await actions.connectManually(access, refresh, expiry) { showsForm = false }
                } cancel: {
                    showsForm = false
                }
            } else {
                buttons
            }
            if snapshot.isWorking {
                Text("Checking the connection…")
                    .font(MeterFont.body(12, .semibold))
                    .foregroundStyle(Palette.inkMuted)
            } else if let message = snapshot.message {
                Text(message)
                    .font(MeterFont.body(12, .bold))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("Allow Keychain access?", isPresented: $showsConsent) {
            Button("Connect") { Task { await actions.connectAutomatically() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Claude Meter reads Claude Code's login from your Keychain to check your usage. "
                    + "macOS may ask you to allow it. Claude Meter never changes or deletes that login."
            )
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if snapshot.connection != .automatic {
                Button("Connect automatically") {
                    if snapshot.needsKeychainConsent {
                        showsConsent = true
                    } else {
                        Task { await actions.connectAutomatically() }
                    }
                }
                .buttonStyle(RaisedButtonStyle())
                .fixedSize()
            }
            Button {
                showsForm = true
            } label: {
                ChunkyButtonLabel(
                    title: snapshot.connection == .manual
                        ? "Update tokens…" : "Enter tokens manually…",
                    symbol: "key")
            }
            .buttonStyle(QuietButtonStyle(radius: 12))
            if snapshot.connection != .off {
                Button {
                    Task { await actions.disconnect() }
                } label: {
                    ChunkyButtonLabel(title: "Disconnect", symbol: "xmark.circle")
                }
                .buttonStyle(QuietButtonStyle(radius: 12))
            }
        }
        .disabled(snapshot.isWorking)
    }
}
