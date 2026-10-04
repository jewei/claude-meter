import AppKit
import MeterApp

/// The app's entry point. The app target calls ``run(updater:)`` once from `main`.
@MainActor public enum ClaudeMeterApplication {
    public static func run(updater: any Updater) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.run()
        exit(0)
    }
}
