import UserNotifications

/// Shows alerts while the app is active, and opens the popover when one is clicked.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let onOpen: @MainActor @Sendable () -> Void

    init(onOpen: @escaping @MainActor @Sendable () -> Void) {
        self.onOpen = onOpen
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await onOpen()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
