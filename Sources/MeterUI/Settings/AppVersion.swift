import Foundation

/// The running app's version and build from its Info.plist.
struct AppVersion: Equatable {
    let version: String?
    let build: String?

    static var current: AppVersion {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppVersion(
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String)
    }

    /// `4.0.0 (400)`, `4.0.0`, or `—`.
    var text: String {
        guard let version, !version.isEmpty else { return "—" }
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }
}
