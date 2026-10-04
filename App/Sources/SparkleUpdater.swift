import AppKit
import MeterApp
import Observation
import Sparkle

/// Sparkle behind the app's ``Updater`` contract.
///
/// Scheduled checks use gentle reminders. When Sparkle would show a found update without the
/// user's focus, the app sets ``isUpdateAvailable`` instead, and the user opens the update
/// from the menu bar when it suits them.
@MainActor @Observable final class SparkleUpdater: Updater {
    private(set) var canCheckForUpdates = false
    private(set) var lastCheckDate: Date?
    private(set) var isUpdateAvailable = false
    /// Sparkle owns this setting. This copy exists only so that views observe changes.
    private var checksAutomatically = false

    var automaticallyChecksForUpdates: Bool {
        get { checksAutomatically }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            checksAutomatically = controller.updater.automaticallyChecksForUpdates
        }
    }

    private let controller: SPUStandardUpdaterController
    /// Sparkle keeps a weak reference to its delegate, so the updater keeps it alive.
    private let reminders: GentleReminders
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init() {
        let reminders = GentleReminders()
        self.reminders = reminders
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: reminders
        )
        reminders.owner = self

        // Sparkle changes these properties only on the main thread and reports them with KVO.
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
                [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) {
                [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastCheckDate = updater.lastUpdateCheckDate }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) {
                [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.checksAutomatically = updater.automaticallyChecksForUpdates
                }
            },
        ]
        controller.startUpdater()
    }

    func checkForUpdates() {
        // The app has no Dock icon. Without activation, Sparkle's window opens behind the
        // frontmost app.
        NSApplication.shared.activate()
        controller.updater.checkForUpdates()
    }

    /// Receives Sparkle's user-driver callbacks, which Sparkle sends on the main thread.
    @MainActor
    private final class GentleReminders: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
        weak var owner: SparkleUpdater?

        var supportsGentleScheduledUpdateReminders: Bool { true }

        func standardUserDriverShouldHandleShowingScheduledUpdate(
            _ update: SUAppcastItem,
            andInImmediateFocus immediateFocus: Bool
        ) -> Bool {
            // Sparkle shows the update itself only when it would get the user's focus anyway,
            // for example just after launch. Otherwise the app shows a reminder.
            immediateFocus
        }

        func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool,
            forUpdate update: SUAppcastItem,
            state: SPUUserUpdateState
        ) {
            if !handleShowingUpdate {
                owner?.isUpdateAvailable = true
            }
        }

        func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            owner?.isUpdateAvailable = false
        }

        func standardUserDriverWillFinishUpdateSession() {
            owner?.isUpdateAvailable = false
        }
    }
}
