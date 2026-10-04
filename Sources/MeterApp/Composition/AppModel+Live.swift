import Foundation
import MeterDomain
import MeterPlatform

extension AppModel {
    /// The model for the running app, with live providers and storage.
    public static func live(updater: any Updater) -> AppModel {
        let settings = SettingsStore(store: DefaultsStore())
        let usage = UsageStore(
            providers: [], archive: ReadingArchive(file: ReadingArchive.standardFile))
        let scheduler = RefreshScheduler(store: usage, display: DisplaySleepMonitor())
        return AppModel(settings: settings, usage: usage, scheduler: scheduler, updater: updater)
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
        return DiagnosticsReport(sections: [app, readings])
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
