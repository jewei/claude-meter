import Foundation
import MeterDomain
import MeterPlatform

extension AppModel {
    /// The model for the running app, with live providers and storage.
    /// Starts refreshing at once; the first refresh waits for the saved readings to load.
    public static func live(updater: any Updater) -> AppModel {
        let defaults = DefaultsStore()
        let settings = SettingsStore(store: defaults)
        let providers = LiveProviders(settings: settings, store: defaults)
        let logFile = LogFile.shared
        let archive = ReadingArchive(file: ReadingArchive.standardFile, logFile: logFile)
        let usage = UsageStore(
            providers: providers.usageProviders, historyProviders: providers.historyProviders,
            archive: archive)
        let scheduler = RefreshScheduler(store: usage, display: DisplaySleepMonitor())
        let model = AppModel(
            settings: settings, usage: usage, scheduler: scheduler, updater: updater,
            logFile: logFile, providers: providers)
        Task { await model.start(archive: archive) }
        return model
    }
}
