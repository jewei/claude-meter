import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`.
///
/// The system owns the state: Settings reads ``status`` each time it appears instead of
/// storing its own copy, so a change in System Settings shows at once.
@MainActor public enum LoginItem {
    public enum Status: Equatable, Sendable {
        case enabled
        case disabled
        /// Registered, but the user must allow it in System Settings > Login Items.
        case requiresApproval
        /// The app is not in a place where macOS can launch it, such as a test run.
        case unavailable

        /// Whether the switch shows on. A login item that waits for approval counts as on.
        public var isOn: Bool {
            self == .enabled || self == .requiresApproval
        }

        /// What the user must do, if anything.
        public var note: String? {
            switch self {
            case .enabled, .disabled: nil
            case .requiresApproval: "Waiting for approval in System Settings > Login Items."
            case .unavailable:
                "macOS cannot start this copy at login. Move Claude Meter to Applications first."
            }
        }
    }

    public static var status: Status {
        status(of: SMAppService.mainApp.status)
    }

    static func status(of status: SMAppService.Status) -> Status {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    /// Registers or unregisters the app. Returns nil on success, or a short sentence that
    /// tells the user what to do.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled, service.status != .requiresApproval else {
                    return nil
                }
                try service.register()
            } else {
                guard service.status != .notRegistered else { return nil }
                try service.unregister()
            }
            return nil
        } catch {
            Log(.app).error("Launch at login \(enabled ? "register" : "unregister") failed", error)
            let verb = enabled ? "turn on" : "turn off"
            return "Claude Meter could not \(verb) launch at login. "
                + "Change it in System Settings > General > Login Items."
        }
    }

    /// Opens System Settings at Login Items, where the user approves the item.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
