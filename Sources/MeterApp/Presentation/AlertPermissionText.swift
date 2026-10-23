import Foundation
import MeterPlatform

/// The note under the alert switches in Settings > Appearance.
public enum AlertPermissionText {
    /// Says how to turn notifications on when macOS blocks them and an alert is on. Nil
    /// otherwise.
    public static func notice(
        _ authorization: NotificationAuthorization?, alerts: AlertSettings
    ) -> String? {
        guard authorization == .denied, !alerts.enabledKinds.isEmpty else { return nil }
        return "Notifications are off for Claude Meter. Turn them on in System Settings > "
            + "Notifications."
    }
}
