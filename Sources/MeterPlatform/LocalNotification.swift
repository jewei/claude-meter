import Foundation

/// One local notification, as the app posts it.
public struct LocalNotification: Equatable, Sendable {
    /// A notification with the same id replaces the older one.
    public let id: String
    public let title: String
    public let body: String

    public init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

/// Whether macOS lets the app post notifications.
public enum NotificationAuthorization: Equatable, Sendable {
    /// The app has not asked yet.
    case notDetermined
    case denied
    case authorized
}

/// Posts local notifications. ``UserNotificationPoster`` is the live type; tests use a fake.
public protocol NotificationPosting: Sendable {
    func authorization() async -> NotificationAuthorization
    /// Shows the system prompt the first time. Returns whether posting is allowed.
    func requestAuthorization() async -> Bool
    /// Returns false when macOS rejects the request.
    func post(_ notification: LocalNotification) async -> Bool
}
