import Foundation
import MeterDomain
import MeterPlatform

extension AppModel {
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
                DiagnosticFact(
                    "Refresh interval",
                    scheduler?.isConstrained == true
                        ? "15 min (Low Power Mode or heat)" : "5 min"),
            ])
        let readings = DiagnosticsReport.Section(
            title: "Readings",
            facts: ProviderID.allCases.map { id in
                DiagnosticFact(id.displayName, Self.describe(usage.readings[id]))
            })
        var sections = [app, readings]
        let providers = self.providers?.diagnostics ?? []
        if !providers.isEmpty {
            let collected = await withTaskGroup(
                of: (Int, DiagnosticsReport.Section).self
            ) { group in
                for (index, (id, provider)) in providers.enumerated() {
                    group.addTask {
                        (
                            index,
                            DiagnosticsReport.Section(
                                title: id.displayName, facts: await provider.diagnostics())
                        )
                    }
                }
                var results: [(Int, DiagnosticsReport.Section)] = []
                results.reserveCapacity(providers.count)
                for await pair in group { results.append(pair) }
                return results.sorted { $0.0 < $1.0 }.map(\.1)
            }
            sections += collected
        }
        return DiagnosticsReport(sections: sections)
    }

    /// `current, 2 accounts, 2026-10-04T12:00:00Z`, `stale since …: Offline.`,
    /// `failed: Offline.`, or `none`.
    static func describe(_ reading: Reading<ProviderUsage>?) -> String {
        switch reading {
        case nil: "none"
        case .current(let usage, let date):
            "current, \(accounts(usage.accounts.count)), \(date.formatted(.iso8601))"
        case .stale(_, let date, let issue):
            "stale since \(date.formatted(.iso8601)): \(issue.message)"
        case .failed(let issue, _): "failed: \(issue.message)"
        }
    }

    private static func accounts(_ count: Int) -> String {
        count == 1 ? "1 account" : "\(count) accounts"
    }
}
