import Foundation
import MeterDomain
import MeterPlatform

extension AppModel {
    /// The model for the running app, with live providers and storage.
    /// Starts refreshing at once; the first refresh waits for the saved readings to load.
    /// - Parameter notifications: The live poster. Only the app creates one
    ///   (``UserNotificationPoster``).
    public static func live(
        updater: any Updater, notifications: any NotificationPosting
    ) -> AppModel {
        let defaults = DefaultsStore()
        let settings = SettingsStore(store: defaults)
        let providers = LiveProviders(settings: settings, store: defaults)
        let logFile = LogFile.shared
        let archive = ReadingArchive(file: ReadingArchive.standardFile, logFile: logFile)
        let usage = UsageStore(
            providers: providers.usageProviders, historyProviders: providers.historyProviders,
            archive: archive)
        let scheduler = RefreshScheduler(
            store: usage, display: DisplaySleepMonitor(), power: PowerStateMonitor())
        let model = AppModel(
            settings: settings, usage: usage, scheduler: scheduler, updater: updater,
            logFile: logFile, providers: providers, notifications: notifications)
        Task { await model.start(archive: archive) }
        return model
    }
}
