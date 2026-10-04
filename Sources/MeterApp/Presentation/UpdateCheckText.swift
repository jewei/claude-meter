import Foundation

/// Copy for the Updates section of Settings > Advanced.
public enum UpdateCheckText {
    /// `Last checked 5m ago`, or `Not checked yet`.
    public static func lastChecked(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not checked yet" }
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite else { return "Not checked yet" }
        switch max(0, seconds) {
        case ..<60: return "Last checked just now"
        case ..<3_600: return "Last checked \(Int(seconds / 60))m ago"
        case ..<86_400: return "Last checked \(Int(seconds / 3_600))h ago"
        default: return "Last checked \(Int(seconds / 86_400))d ago"
        }
    }

    /// `Installed v4.0.0 (400)`, or the update notice when one is waiting.
    public static func status(version: String?, build: String?, isUpdateAvailable: Bool) -> String {
        if isUpdateAvailable { return "An update is available." }
        guard let version, !version.isEmpty else { return "Installed version unknown" }
        guard let build, !build.isEmpty, build != version else { return "Installed v\(version)" }
        return "Installed v\(version) (\(build))"
    }
}
