import Foundation

/// Names of the app's own storage, so a development build never touches the data of an
/// installed copy. Release builds keep the stable names; tests see the release names too.
public enum AppIdentity {
    public static let releaseBundleID = "com.jewei.claudemeter"

    /// True for the Debug build, whose bundle identifier ends in `.debug`.
    public static let isDevelopmentBuild =
        Bundle.main.bundleIdentifier == releaseBundleID + ".debug"

    /// The folder name under Application Support and Logs: `ClaudeMeter`, or
    /// `ClaudeMeter Debug` for a development build.
    public static var folderName: String {
        isDevelopmentBuild ? "ClaudeMeter Debug" : "ClaudeMeter"
    }

    /// A Keychain service owned by this app, such as `com.jewei.claudemeter.claude-oauth`.
    public static func keychainService(_ name: String) -> String {
        (isDevelopmentBuild ? releaseBundleID + ".debug" : releaseBundleID) + "." + name
    }
}
