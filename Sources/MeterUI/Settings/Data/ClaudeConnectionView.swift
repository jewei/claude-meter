import MeterApp
import MeterDomain
import SwiftUI

/// The Claude connection: both logins' states and the actions for the current connection.
///
/// "Connect automatically" asks for Keychain consent first when the user has not given it.
/// "Enter tokens manually" opens a form whose Cancel discards the draft, abandons a Connect
/// that is still running, and keeps the stored credentials. Disconnect asks in the page first
/// when it would delete tokens that the user entered.
struct ClaudeConnectionView: View {
    /// What the view shows, read from ``ClaudeSettingsModel``.
    struct Snapshot: Equatable {
        var connection: ClaudeSettings.Connection
        var automaticStatus: SignInStatus?
        var manualStatus: SignInStatus?
        var isWorking = false
        var message: String?
        /// The message reports a failure.
        var messageIsProblem = false
        var needsKeychainConsent = false
    }

    struct Actions {
        var connectAutomatically: () async -> Void
        /// Returns true when the tokens were verified and saved.
        var connectManually: (_ access: String, _ refresh: String?, _ expiry: Date?) async -> Bool
        /// Abandons a Connect that is still running; it stores nothing afterwards.
        var abandonConnect: () async -> Void
        var disconnect: () async -> Void
    }

    /// What shows below the sign-in states.
    enum Stage: Equatable {
        case buttons
        case tokenForm
        case confirmingDisconnect
    }

    let snapshot: Snapshot
    let actions: Actions

    @State private var stage: Stage
    @State private var showsConsent = false

    init(snapshot: Snapshot, actions: Actions, stage: Stage = .buttons) {
        self.snapshot = snapshot
        self.actions = actions
        _stage = State(initialValue: stage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SignInStatusLine(
                    status: DataSourceText.claudeCode(snapshot.automaticStatus),
                    label: "Automatic")
                SignInStatusLine(
                    status: DataSourceText.manualTokens(snapshot.manualStatus), label: "Manual")
            }
            stageContent
            if snapshot.isWorking {
                Text("Checking the connection…")
                    .font(MeterFont.body(12, .semibold))
                    .foregroundStyle(Palette.inkMuted)
            } else if let message = snapshot.message {
                messageLine(message)
            }
        }
        .alert("Allow Keychain access?", isPresented: $showsConsent) {
            Button("Connect") { Task { await actions.connectAutomatically() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Claude Meter reads Claude Code's login from your Keychain to check your usage. "
                    + "It never shows a Keychain prompt, and it never changes or deletes that login."
            )
        }
    }

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .buttons:
            buttons
        case .tokenForm:
            ManualTokenForm(isWorking: snapshot.isWorking) { access, refresh, expiry in
                if await actions.connectManually(access, refresh, expiry) { stage = .buttons }
            } cancel: {
                stage = .buttons
                Task { await actions.abandonConnect() }
            }
        case .confirmingDisconnect:
            if let confirmation = disconnectConfirmation {
                InlineConfirmation(confirmation: confirmation) {
                    stage = .buttons
                    Task { await actions.disconnect() }
                } cancel: {
                    stage = .buttons
                }
            } else {
                buttons
            }
        }
    }

    private var disconnectConfirmation: DataSourceText.Confirmation? {
        DataSourceText.disconnectConfirmation(
            connection: snapshot.connection, manualStatus: snapshot.manualStatus)
    }

    /// A failure in the error ink with a warning symbol; other news in ink.
    private func messageLine(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if snapshot.messageIsProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(message)
                .font(MeterFont.body(12, .bold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(snapshot.messageIsProblem ? Palette.energyEmptyInk : Palette.ink)
        .accessibilityElement(children: .combine)
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
                stage = .tokenForm
            } label: {
                ChunkyButtonLabel(
                    title: snapshot.connection == .manual
                        ? "Update tokens…" : "Enter tokens manually…",
                    symbol: "key")
            }
            .buttonStyle(.chunky)
            if snapshot.connection != .off {
                Button {
                    if disconnectConfirmation == nil {
                        Task { await actions.disconnect() }
                    } else {
                        stage = .confirmingDisconnect
                    }
                } label: {
                    ChunkyButtonLabel(title: "Disconnect", symbol: "xmark.circle")
                }
                .buttonStyle(.chunky)
            }
        }
        .disabled(snapshot.isWorking)
    }
}
