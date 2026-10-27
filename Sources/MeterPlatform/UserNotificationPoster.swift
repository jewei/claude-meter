import Foundation
import UserNotifications

/// ``NotificationPosting`` over `UNUserNotificationCenter`. Only the running app creates one:
/// the notification center traps in a process without an app bundle, such as a test run.
public struct UserNotificationPoster: NotificationPosting {
    public init() {}

    public func authorization() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional: return .authorized
        default: return .denied
        }
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [
                .alert, .sound,
            ])
        } catch {
            return false
        }
    }

    public func post(_ notification: LocalNotification) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: notification.id, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }
}
