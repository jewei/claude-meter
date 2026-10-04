import Foundation
import MeterDomain
import MeterPlatform

extension AppModel {
    /// Restores saved readings, applies the log setting, and starts refreshing. Call once.
    func start(archive: ReadingArchive?) async {
        let current = settings.settings
        if let archive {
            let saved = await archive.load()
            usage.restore(saved.filter { current.enabledProviders.contains($0.key) })
        }
        LogFile.shared.setEnabled(current.writesLogFile)
        scheduler?.update(Self.refreshConfiguration(current))
        await claudeSettings?.reload()
        await codexSettings?.reload()
    }

    /// Refreshing runs once the welcome is done and while the user has not paused it.
    static func refreshConfiguration(_ settings: Settings) -> RefreshConfiguration {
        RefreshConfiguration(
            isActive: settings.hasCompletedOnboarding && !settings.isPaused,
            enabledProviders: settings.enabledProviders)
    }

    /// Applies a saved settings change to the services that depend on it.
    func settingsDidChange(from old: Settings, to new: Settings) {
        if old.writesLogFile != new.writesLogFile {
            LogFile.shared.setEnabled(new.writesLogFile)
        }
        let configuration = Self.refreshConfiguration(new)
        if configuration != Self.refreshConfiguration(old) {
            scheduler?.update(configuration)
        }
        if old.claude.connection != new.claude.connection
            || old.claude.extraDirectories != new.claude.extraDirectories
            || old.claude.disabledAccounts != new.claude.disabledAccounts
        {
            scheduler?.refreshNow([.claude])
        }
        if old.codex.extraHomes != new.codex.extraHomes {
            scheduler?.refreshNow([.codex])
            Task { await codexSettings?.reload() }
        }
    }
}
