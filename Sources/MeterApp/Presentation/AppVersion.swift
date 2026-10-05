import Foundation

/// The running app's version and build, and how Settings writes them.
public struct AppVersion: Equatable, Sendable {
    public let version: String?
    public let build: String?

    public init(version: String?, build: String?) {
        self.version = version
        self.build = build
    }

    /// The version and build from the app's Info.plist.
    public static var current: AppVersion {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppVersion(
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String)
    }

    /// Whether the version is known. An empty version is not.
    public var isKnown: Bool {
        !(version ?? "").isEmpty
    }

    /// `4.0.0 (400)`; `4.0.0` when the build is missing or the same as the version; `—` when
    /// the version is unknown.
    public var text: String {
        guard let version, !version.isEmpty else { return "—" }
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (\(build))"
    }
}
