import AppKit
import MeterApp

/// The app's entry point. The app target calls ``run(updater:)`` once from `main`.
@MainActor public enum ClaudeMeterApplication {
    /// Runs the menu-bar app with no Dock icon until it quits.
    public static func run(updater: any Updater) -> Never {
        let application = NSApplication.shared
        let controller = AppController(updater: updater)
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        // The delegate property is weak; keep the controller alive for the whole run.
        withExtendedLifetime(controller) {
            application.run()
        }
        exit(0)
    }
}
