import ClaudeMeterCore
import ClaudeMeterProviders
import Foundation
import SwiftUI

private enum OAuthSetupState: Equatable {
    case idle
    case promptAuto
    case promptNoAuto
    case manualEntry
    case verifying
    case connectedAuto
    case connectedManual
    case error(String)
}

struct OAuthConnectionSection: View {
    let appState: AppState

    @AppStorage(AppSettings.oauthSourceEnabledKey) private var oauthSourceEnabled = true
    @AppStorage(AppSettings.oauthModeKey) private var oauthMode = ""
    @State private var state: OAuthSetupState = .idle
    @State private var showAccessToken = false
    @State private var showRefreshToken = false
    @State private var manualAccess = ""
    @State private var manualRefresh = ""
    @State private var testResult = ""
    @AppStorage("oauthKeychainConsentAcknowledged")
    private var keychainConsentAcknowledged = false
    @State private var showKeychainConsent = false

    var body: some View {
        Group {
            if oauthSourceEnabled {
                stateContent
            }
        }
        .onAppear { loadState() }
        .alert("Connect Claude Code?", isPresented: $showKeychainConsent) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                keychainConsentAcknowledged = true
                connectAutoDetected()
            }
        } message: {
            Text(
                "Claude Meter will ask macOS for access to Claude Code's OAuth credentials. Tokens stay in Keychain and are never shown or copied."
            )
        }
    }

    private var isConnected: Bool {
        state == .connectedAuto || state == .connectedManual
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle:
            EmptyView()

        case .promptAuto:
            HStack(spacing: 10) {
                Button("Connect") { requestAutoConnection() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Enter manually") { state = .manualEntry }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

        case .promptNoAuto:
            Button("Enter tokens manually") { state = .manualEntry }
                .buttonStyle(.bordered)
                .controlSize(.small)

        case .manualEntry:
            manualEntryFields

        case .verifying:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Verifying…").font(.caption).foregroundStyle(.secondary)
            }

        case .connectedAuto, .connectedManual:
            if isConnected {
                Button {
                    reauthenticate()
                } label: {
                    Label("Re-authenticate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if state == .connectedAuto {
                Text(
                    "Reads Claude Code's Keychain; refreshed tokens stay in memory for this session only."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !testResult.isEmpty {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("Error") ? .red : .green)
            }

        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Retry") { retryAuto() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Enter manually") { state = .manualEntry }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var manualEntryFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Access Token")
                    .font(.caption)
                    .frame(width: 88, alignment: .leading)
                Group {
                    if showAccessToken {
                        TextField(
                            "", text: $manualAccess,
                            prompt: Text("oidc-…").foregroundColor(.secondary))
                    } else {
                        SecureField(
                            "", text: $manualAccess,
                            prompt: Text("oidc-…").foregroundColor(.secondary))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                Button {
                    showAccessToken.toggle()
                } label: {
                    Image(systemName: showAccessToken ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                Text("Refresh Token")
                    .font(.caption)
                    .frame(width: 88, alignment: .leading)
                Group {
                    if showRefreshToken {
                        TextField(
                            "", text: $manualRefresh,
                            prompt: Text("Refresh token").foregroundColor(.secondary))
                    } else {
                        SecureField(
                            "", text: $manualRefresh,
                            prompt: Text("Refresh token").foregroundColor(.secondary))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                Button {
                    showRefreshToken.toggle()
                } label: {
                    Image(systemName: showRefreshToken ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 10) {
                Button("Save and connect") { saveManual() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        manualAccess.trimmingCharacters(in: .whitespaces).isEmpty
                            || manualRefresh.trimmingCharacters(in: .whitespaces).isEmpty)
                if oauthMode.isEmpty {
                    Button("Cancel") {
                        state = disconnectedState()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                if isConnected {
                    Button("Disconnect") { disconnect() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func loadState() {
        switch oauthMode {
        case "auto": state = .connectedAuto
        case "manual": state = OAuthKeychain.loadManual() != nil ? .connectedManual : .manualEntry
        default: state = disconnectedState()
        }
    }

    private func reauthenticate() {
        if oauthMode == "manual" {
            state = .manualEntry
        } else {
            requestAutoConnection()
        }
    }

    private func requestAutoConnection() {
        if keychainConsentAcknowledged {
            connectAutoDetected()
        } else {
            showKeychainConsent = true
        }
    }

    private func connectAutoDetected() {
        state = .verifying
        Task {
            let result = await Task.detached { OAuthKeychain.loadResult() }.value
            let credentials: OAuthCredentials
            switch result {
            case .found(let found):
                credentials = found
            case .missing:
                state = .error("Claude Code credentials were not found in Keychain")
                return
            case .temporarilyUnavailable:
                state = .error("Keychain access is unavailable. Unlock your Mac and try again.")
                return
            case .invalid:
                state = .error("Claude Code credentials in Keychain are invalid")
                return
            }
            do {
                let (session, week) = try await OAuthPipeline.verify(credentials: credentials)
                oauthSourceEnabled = true
                oauthMode = "auto"
                testResult = "Session \(Int(session))%  ·  Week \(Int(week))%"
                state = .connectedAuto
                appState.rebuildPipeline()
                appState.refreshNow()
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func saveManual() {
        let accessToken = manualAccess.trimmingCharacters(in: .whitespaces)
        let refreshToken = manualRefresh.trimmingCharacters(in: .whitespaces)
        guard !accessToken.isEmpty, !refreshToken.isEmpty else { return }
        OAuthKeychain.saveManual(accessToken: accessToken, refreshToken: refreshToken)
        state = .verifying
        Task {
            do {
                guard let credentials = OAuthKeychain.loadManual() else {
                    throw URLError(.badServerResponse)
                }
                let (session, week) = try await OAuthPipeline.verify(credentials: credentials)
                oauthSourceEnabled = true
                oauthMode = "manual"
                testResult = "Session \(Int(session))%  ·  Week \(Int(week))%"
                manualAccess = ""
                manualRefresh = ""
                state = .connectedManual
                appState.rebuildPipeline()
                appState.refreshNow()
            } catch {
                OAuthKeychain.deleteManual()
                state = .error("Verification failed: \(error.localizedDescription)")
            }
        }
    }

    private func retryAuto() {
        requestAutoConnection()
    }

    private func disconnect() {
        if oauthMode == "manual" { OAuthKeychain.deleteManual() }
        OAuthPipeline.clearCachedCredentials()
        oauthMode = ""
        testResult = ""
        manualAccess = ""
        manualRefresh = ""
        appState.rebuildPipeline()
        state = disconnectedState()
    }

    private func disconnectedState() -> OAuthSetupState {
        switch OAuthKeychain.credentialAvailability() {
        case .available, .temporarilyUnavailable: return .promptAuto
        case .missing: return .promptNoAuto
        }
    }
}
