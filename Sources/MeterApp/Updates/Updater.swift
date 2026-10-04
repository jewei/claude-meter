import Foundation

/// Software updates. The app target implements it with Sparkle; tests and previews use
/// ``DisabledUpdater``. Implementations are `@Observable`, so views see changes.
@MainActor public protocol Updater: AnyObject {
    /// Whether this build can update itself at all. False for development and unsigned
    /// builds, which never check.
    var isAvailable: Bool { get }
    /// Whether the app checks for updates in the background (Sparkle's own setting).
    var automaticallyChecksForUpdates: Bool { get set }
    var lastCheckDate: Date? { get }
    var canCheckForUpdates: Bool { get }
    /// A background check found an update that the user has not installed yet.
    var isUpdateAvailable: Bool { get }
    /// Starts a user-initiated check, which shows Sparkle's own window.
    func checkForUpdates()
}

/// An updater that never updates, for tests, previews, and unsigned development builds.
@MainActor public final class DisabledUpdater: Updater {
    public let isAvailable = false
    public var automaticallyChecksForUpdates = false
    public let lastCheckDate: Date? = nil
    public let canCheckForUpdates = false
    public let isUpdateAvailable = false

    public init() {}

    public func checkForUpdates() {}
}
