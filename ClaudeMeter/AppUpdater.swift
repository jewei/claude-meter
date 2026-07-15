import AppKit

#if !SWIFT_PACKAGE
    import Sparkle
#endif

@MainActor
final class AppUpdater {
    #if SWIFT_PACKAGE
        private final class StubDelegate: NSObject {
            weak var appState: AppState?
        }

        private let delegate = StubDelegate()
    #else
        private let delegate: UpdaterDelegate
        private let controller: SPUStandardUpdaterController
    #endif

    weak var appState: AppState? {
        get { delegate.appState }
        set { delegate.appState = newValue }
    }

    init(startingUpdater: Bool) {
        #if SWIFT_PACKAGE
            _ = startingUpdater
        #else
            let delegate = UpdaterDelegate()
            self.delegate = delegate
            self.controller = SPUStandardUpdaterController(
                startingUpdater: startingUpdater,
                updaterDelegate: nil,
                userDriverDelegate: delegate
            )
        #endif
    }

    func checkForUpdates() {
        NSApp.setActivationPolicy(.regular)
        #if !SWIFT_PACKAGE
            controller.updater.checkForUpdates()
        #endif
    }
}

#if !SWIFT_PACKAGE
    // @unchecked Sendable + nonisolated(unsafe): Sparkle calls these from the main thread;
    // mutations hop to MainActor via Task for safe off-main fallback.
    private final class UpdaterDelegate: NSObject, SPUStandardUserDriverDelegate,
        @unchecked Sendable
    {
        nonisolated(unsafe) weak var appState: AppState?

        var supportsGentleScheduledUpdateReminders: Bool { true }

        func standardUserDriverShouldHandleShowingScheduledUpdate(
            _ update: SUAppcastItem,
            andInImmediateFocus immediateFocus: Bool
        ) -> Bool {
            // Delegate handles background scheduled checks (immediateFocus == false);
            // let Sparkle handle any check the user explicitly triggered.
            immediateFocus
        }

        func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool,
            forUpdate update: SUAppcastItem,
            state: SPUUserUpdateState
        ) {
            Task { @MainActor [weak appState] in
                guard let appState else { return }
                if handleShowingUpdate {
                    NSApp.setActivationPolicy(.regular)
                } else {
                    appState.updateAvailable = true
                    await appState.notificationEngine.postUpdateAvailable(
                        version: update.displayVersionString
                    )
                }
            }
        }

        func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            Task { @MainActor [weak appState] in
                appState?.updateAvailable = false
            }
        }

        func standardUserDriverWillFinishUpdateSession() {
            Task { @MainActor [weak appState] in
                appState?.updateAvailable = false
                // Keep the app activatable while our Settings window is open —
                // dropping an LSUIElement app to .accessory with a visible window
                // strands it without Cmd-Tab focus. Sparkle's own windows are
                // closing at this point; match ours by title.
                let settingsOpen = NSApp.windows.contains {
                    $0.isVisible && $0.title == "Claude Meter — Settings"
                }
                if !settingsOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
#endif
