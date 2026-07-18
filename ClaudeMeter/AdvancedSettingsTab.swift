import Foundation
import ServiceManagement
import SwiftUI

struct AdvancedSettingsTab: View {
    let appState: AppState

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var launchAtLoginNeedsApproval = false
    @AppStorage("SUEnableAutomaticChecks") private var automaticallyCheckForUpdates = true
    @State private var showingDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeading("App")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        RaisedTile(fill: Color(hex: "C77DFF"), size: 40, radius: 11) {
                            Image(systemName: "power").font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        cardText("Launch at login", "Start Claude Meter when you log in.")
                        Spacer(minLength: 8)
                        Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                    }
                    if launchAtLoginNeedsApproval {
                        HStack(spacing: 8) {
                            Image(systemName: "hourglass")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.pfEnergyLow)
                            Text("Waiting for approval in System Settings › Login Items.")
                                .font(PFont.body(12, .semibold))
                                .foregroundStyle(Color.pfInkMuted)
                            Spacer(minLength: 8)
                            Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                                .font(PFont.body(12, .bold))
                        }
                    }
                }
                .padding(16).chunkyCard(radius: 18)

                sectionHeading("Updates")
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        RaisedTile(fill: Color(hex: "25B6F0"), size: 40, radius: 11) {
                            Image(systemName: "arrow.clockwise").font(
                                .system(size: 17, weight: .bold)
                            )
                            .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check for updates automatically")
                                .font(PFont.display(16, .semibold)).foregroundStyle(Color.pfInk)
                            Text(updateStatus).font(PFont.body(12, .bold))
                                .foregroundStyle(updateStatusColor)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: $automaticallyCheckForUpdates).toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Divider().overlay(Color.pfCardBorder)
                    HStack(spacing: 12) {
                        Button {
                            appState.checkForUpdates()
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Check for updates…").font(PFont.display(13, .semibold))
                            }
                            .foregroundStyle(Color.pfInk).padding(.horizontal, 14).padding(
                                .vertical, 9
                            )
                            .chunkyCard(radius: 12)
                        }
                        .buttonStyle(.plain)
                        if let last = lastCheckedText {
                            Text(last).font(PFont.body(12, .semibold)).foregroundStyle(
                                Color.pfInkMuted)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(16).chunkyCard(radius: 18)

                sectionHeading("Diagnostics")
                HStack(spacing: 12) {
                    RaisedTile(fill: Color(hex: "FF9D0A"), size: 40, radius: 11) {
                        Image(systemName: "waveform.path.ecg").font(
                            .system(size: 16, weight: .bold)
                        )
                        .foregroundStyle(.white)
                    }
                    cardText("Diagnostics", "Inspect logs, data sources & raw limits.")
                    Spacer(minLength: 8)
                    Button {
                        showingDiagnostics = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("Open Diagnostics…").font(PFont.display(13, .semibold))
                            Image(systemName: "chevron.right").font(
                                .system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(Color.pfInk).padding(.horizontal, 14).padding(.vertical, 9)
                        .chunkyCard(radius: 12)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16).chunkyCard(radius: 18)
            }
            .padding(20)
        }
        .onAppear { syncLaunchAtLoginFromSystem() }
        .onChange(of: launchAtLogin) { _, newValue in applyLaunchAtLogin(newValue) }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView()
                .environmentObject(appState)
                .frame(minWidth: 480, minHeight: 380)
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(PFont.display(22, .bold))
            .foregroundStyle(Color.pfInk)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cardText(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(PFont.display(16, .semibold)).foregroundStyle(Color.pfInk)
            Text(subtitle).font(PFont.body(12, .semibold)).foregroundStyle(Color.pfInkMuted)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var updateStatus: String {
        appState.updateAvailable
            ? "Update available · click to install" : "Installed v\(appVersion)"
    }

    private var updateStatusColor: Color {
        appState.updateAvailable ? .pfEnergyLow : .pfHeroFullInk
    }

    private var lastCheckedText: String? {
        guard let date = UserDefaults.standard.object(forKey: "SULastCheckTime") as? Date
        else { return nil }
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "Last checked just now" }
        if elapsed < 3600 { return "Last checked \(elapsed / 60)m ago" }
        if elapsed < 86400 { return "Last checked \(elapsed / 3600)h ago" }
        return "Last checked \(elapsed / 86400)d ago"
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                switch SMAppService.mainApp.status {
                case .notRegistered, .notFound:
                    try SMAppService.mainApp.register()
                default:
                    break
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog(
                "Claude Meter: launch-at-login \(enabled ? "register" : "unregister") failed: "
                    + error.localizedDescription)
            syncLaunchAtLoginFromSystem()
            return
        }
        launchAtLoginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    private func syncLaunchAtLoginFromSystem() {
        let status = SMAppService.mainApp.status
        let enabled = status == .enabled || status == .requiresApproval
        if launchAtLogin != enabled {
            launchAtLogin = enabled
        }
        launchAtLoginNeedsApproval = status == .requiresApproval
    }
}
