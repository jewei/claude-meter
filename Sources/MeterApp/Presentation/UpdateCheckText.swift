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

    /// How the status line reads.
    public enum Tone: Equatable, Sendable {
        /// An update is waiting.
        case attention
        /// The installed version is known and current.
        case current
        /// Nothing to report, such as an unknown version.
        case neutral
    }

    /// The status line of a build that cannot update itself (``Updater/isAvailable``).
    public static let unavailable =
        "This build does not update itself. Install a release to get updates."

    /// The status text with its tone. An unknown version is neutral, never a success, and so
    /// is a build that cannot update itself.
    public static func statusLine(
        version: String?, build: String?, isUpdateAvailable: Bool, canUpdate: Bool
    ) -> (text: String, tone: Tone) {
        guard canUpdate else { return (unavailable, .neutral) }
        let text = status(version: version, build: build, isUpdateAvailable: isUpdateAvailable)
        if isUpdateAvailable { return (text, .attention) }
        return (text, AppVersion(version: version, build: build).isKnown ? .current : .neutral)
    }

    /// `Installed v4.0.0 (400)`, or the update notice when one is waiting.
    public static func status(version: String?, build: String?, isUpdateAvailable: Bool) -> String {
        if isUpdateAvailable { return "An update is available." }
        let installed = AppVersion(version: version, build: build)
        return installed.isKnown ? "Installed v\(installed.text)" : "Installed version unknown"
    }
}
