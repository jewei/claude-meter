import Foundation
import MeterDomain
import MeterPlatform

extension AppModel {
    /// The model for the running app, with live providers and storage.
    /// Starts refreshing at once; the first refresh waits for the saved readings to load.
    public static func live(updater: any Updater) -> AppModel {
        let defaults = DefaultsStore()
        let settings = SettingsStore(store: defaults)
        let providers = LiveProviders(settings: settings, store: defaults)
        let archive = ReadingArchive(file: ReadingArchive.standardFile)
        let usage = UsageStore(
            providers: providers.usageProviders, historyProviders: providers.historyProviders,
            archive: archive)
        let scheduler = RefreshScheduler(store: usage, display: DisplaySleepMonitor())
        let model = AppModel(
            settings: settings, usage: usage, scheduler: scheduler, updater: updater,
            logFile: .shared, providers: providers)
        Task { await model.start(archive: archive) }
        return model
    }

    /// Facts for the Diagnostics sheet.
    public func diagnostics() async -> DiagnosticsReport {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let app = DiagnosticsReport.Section(
            title: "App",
            facts: [
                DiagnosticFact("Version", "\(version) (\(build))"),
                DiagnosticFact("macOS", os),
                DiagnosticFact("Updates", settings.settings.isPaused ? "paused" : "running"),
            ])
        let readings = DiagnosticsReport.Section(
            title: "Readings",
            facts: ProviderID.allCases.map { id in
                DiagnosticFact(id.displayName, Self.describe(usage.readings[id]))
            })
        var sections = [app, readings]
        for (id, provider) in providers?.diagnostics ?? [] {
            sections.append(
                DiagnosticsReport.Section(
                    title: id.displayName, facts: await provider.diagnostics()))
        }
        return DiagnosticsReport(sections: sections)
    }

    private static func describe(_ reading: Reading<ProviderUsage>?) -> String {
        switch reading {
        case nil: "none"
        case .current(let usage, let date):
            "current, \(usage.accounts.count) accounts, \(date.formatted(.iso8601))"
        case .stale(_, let date, let issue):
            "stale since \(date.formatted(.iso8601)): \(issue.message)"
        case .failed(let issue, _): "failed: \(issue.message)"
        }
    }
}
