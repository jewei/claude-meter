import AppKit
import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI
import Testing

@testable import ClaudeMeter

private struct VisualFixtureProvider: UsageProvider {
    var id: ProviderID = .claude
    let accounts: [ProviderAccountSnapshot]

    func fetch(now: Date, previous: ProviderSnapshot?, refreshID: UUID) async throws
        -> ProviderSnapshot
    {
        ProviderSnapshot(provider: id, accounts: accounts, fetchedAt: now)
    }
}

/// Opt-in images for human review. The script starts this host with a separate home.
@Suite("Visual capture", .serialized)
struct VisualCaptureTests {
    @Test("Capture synthetic app surfaces")
    @MainActor
    func capture() async throws {
        guard let output = ProcessInfo.processInfo.environment["CLAUDE_METER_VISUAL_OUTPUT"] else {
            return
        }
        #expect(Bundle.main.bundleIdentifier == "com.jewei.ClaudeMeter.VisualCapture.ClaudeMeter")
        guard Bundle.main.bundleIdentifier == "com.jewei.ClaudeMeter.VisualCapture.ClaudeMeter"
        else { return }
        let fixtureHome = try #require(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"])
        #expect(NSHomeDirectory() == fixtureHome)
        guard NSHomeDirectory() == fixtureHome else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let domain = try #require(Bundle.main.bundleIdentifier)
        let previousDefaults = defaults.persistentDomain(forName: domain)
        defaults.removePersistentDomain(forName: domain)
        defer {
            if let previousDefaults {
                defaults.setPersistentDomain(previousDefaults, forName: domain)
            } else {
                defaults.removePersistentDomain(forName: domain)
            }
        }
        defaults.set("auto", forKey: AppSettings.oauthModeKey)
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(true, forKey: AppSettings.oauthSourceEnabledKey)
        defaults.set("claude", forKey: MeterSettings.mainMeterProviderKey)
        defaults.set("work", forKey: MeterSettings.menuBarAccountKey)
        defaults.set(false, forKey: AppSettings.cursorSourceEnabledKey)
        defaults.set(false, forKey: AppSettings.codexSourceEnabledKey)
        defaults.set(false, forKey: AppSettings.grokSourceEnabledKey)
        let now = Date()
        func account(_ id: String, _ label: String, _ used: Double?, stale: Bool = false)
            -> ProviderAccountSnapshot
        {
            ProviderAccountSnapshot(
                id: id, label: label, plan: "Max 20×",
                windows: [
                    UsageWindow(
                        id: "session", title: "Session", kind: .session,
                        usedPercent: used, resetAt: now.addingTimeInterval(11_520)),
                    UsageWindow(
                        id: "weekly", title: "Weekly", kind: .weekly,
                        usedPercent: 36, resetAt: now.addingTimeInterval(543_600)),
                ], observedAt: now, isStale: stale,
                lastError: stale ? "Connection failed. Check your network and try again." : nil)
        }
        for scheme in [ColorScheme.light, .dark] {
            let mode = scheme == .light ? "light" : "dark"
            for style in ["rings", "bars"] {
                defaults.set(style, forKey: MeterSettings.cardStyleKey)
                defaults.set(["claude:work"], forKey: AppSettings.expandedProviderCardsKey)
                let provider = VisualFixtureProvider(accounts: [
                    account("work", "Work", 22), account("personal", "Personal", 86),
                ])
                let store = UsageStore(providers: [provider])
                store.setEnabled(.claude, enabled: true)
                await store.refresh([.claude], now: now)
                let state = AppState(usageStore: store)
                try await render(
                    PopoverView().environmentObject(state), width: 360, height: 780,
                    scheme: scheme,
                    to: directory.appendingPathComponent("popover-\(style)-\(mode).png"))
            }
            defaults.set("rings", forKey: MeterSettings.cardStyleKey)
            let provider = VisualFixtureProvider(accounts: [
                account("work", "Research and development — production account", 97, stale: true)
            ])
            let store = UsageStore(providers: [provider])
            store.setEnabled(.claude, enabled: true)
            await store.refresh([.claude], now: now)
            try await render(
                PopoverView().environmentObject(AppState(usageStore: store)),
                width: 360, height: 650, scheme: scheme,
                to: directory.appendingPathComponent("popover-stale-long-\(mode).png"))
            defaults.set("bars", forKey: MeterSettings.cardStyleKey)
            try await render(
                PopoverView().environmentObject(AppState(usageStore: store)),
                width: 360, height: 650, scheme: scheme,
                to: directory.appendingPathComponent("popover-bars-long-\(mode).png"))
            defaults.set("rings", forKey: MeterSettings.cardStyleKey)
            for (name, used) in [
                ("critical", Optional(97.0)), ("empty", Optional(100.0)), ("unknown", nil),
            ] {
                let fixture = VisualFixtureProvider(accounts: [account("work", "Work", used)])
                let fixtureStore = UsageStore(providers: [fixture])
                fixtureStore.setEnabled(.claude, enabled: true)
                await fixtureStore.refresh([.claude], now: now)
                try await render(
                    PopoverView().environmentObject(AppState(usageStore: fixtureStore)),
                    width: 360, height: 650, scheme: scheme,
                    to: directory.appendingPathComponent("popover-\(name)-\(mode).png"))
            }
            let paused = AppState(usageStore: UsageStore(providers: []))
            paused.setActive(false)
            try await render(
                PopoverView().environmentObject(paused), width: 360, height: 450,
                scheme: scheme, to: directory.appendingPathComponent("popover-paused-\(mode).png"))
            defaults.set("codex", forKey: MeterSettings.mainMeterProviderKey)
            defaults.set(true, forKey: AppSettings.codexSourceEnabledKey)
            defaults.set("bars", forKey: MeterSettings.cardStyleKey)
            let codex = CodexAccount(
                home: URL(fileURLWithPath: "/fixture/codex"), isImplicit: false,
                customName: "Research and development — production account")
            defaults.set(codex.id, forKey: MeterSettings.codexMainMeterAccountKey)
            defaults.set(["codex:\(codex.id)"], forKey: AppSettings.expandedProviderCardsKey)
            let codexReading = ProviderAccountSnapshot(
                id: codex.id, label: codex.displayName, plan: "Pro",
                windows: [
                    UsageWindow(
                        id: "primary", title: "Session", kind: .session, usedPercent: 22,
                        resetAt: now.addingTimeInterval(11_520)),
                    UsageWindow(
                        id: "secondary", title: "Weekly", kind: .weekly, usedPercent: 36,
                        resetAt: now.addingTimeInterval(543_600)),
                ], observedAt: now)
            let codexProvider = VisualFixtureProvider(id: .codex, accounts: [codexReading])
            let codexStore = UsageStore(providers: [codexProvider])
            codexStore.setEnabled(.codex, enabled: true)
            await codexStore.refresh([.codex], now: now)
            try await render(
                PopoverView().environmentObject(
                    AppState(usageStore: codexStore, codexConfiguration: [codex])),
                width: 360, height: 650, scheme: scheme,
                to: directory.appendingPathComponent("popover-codex-long-\(mode).png"))
            defaults.set("claude", forKey: MeterSettings.mainMeterProviderKey)
            defaults.set(false, forKey: AppSettings.codexSourceEnabledKey)
            defaults.set(false, forKey: "hasCompletedOnboarding")
            try await render(
                PopoverView().environmentObject(AppState(usageStore: UsageStore(providers: []))),
                width: 360, height: 450, scheme: scheme,
                to: directory.appendingPathComponent("popover-welcome-\(mode).png"))
            defaults.set(true, forKey: "hasCompletedOnboarding")
            try await render(
                AppearanceSettingsTab(), width: 580, height: 620, scheme: scheme,
                to: directory.appendingPathComponent("settings-appearance-\(mode).png"))
            let settingsState = AppState(usageStore: UsageStore(providers: []))
            defaults.set(false, forKey: AppSettings.oauthSourceEnabledKey)
            try await render(
                SettingsView().environmentObject(settingsState), width: 580, height: 700,
                scheme: scheme, to: directory.appendingPathComponent("settings-data-\(mode).png"))
            defaults.set(true, forKey: AppSettings.oauthSourceEnabledKey)
            try await render(
                AdvancedSettingsTab(appState: settingsState), width: 580, height: 620,
                scheme: scheme,
                to: directory.appendingPathComponent("settings-advanced-\(mode).png"))
            try await render(
                DiagnosticsView().environmentObject(settingsState), width: 580, height: 620,
                scheme: scheme,
                to: directory.appendingPathComponent("settings-diagnostics-\(mode).png"))
            try await render(
                AboutSettingsTab(), width: 580, height: 620, scheme: scheme,
                to: directory.appendingPathComponent("settings-about-\(mode).png"))
        }
    }

    @MainActor
    private func render<Content: View>(
        _ content: Content, width: CGFloat, height: CGFloat, scheme: ColorScheme, to url: URL
    ) async throws {
        let host = NSHostingView(
            rootView:
                content
                .environment(\.colorScheme, scheme)
                .environment(\.controlActiveState, .active)
                .tint(Color.pfHeroFullInk)
                .transaction { $0.disablesAnimations = true }
                .frame(width: width, height: height, alignment: .top)
                .background(Color.pfPopover))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        host.display()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        window.orderOut(nil)
        window.contentView = nil
    }
}
