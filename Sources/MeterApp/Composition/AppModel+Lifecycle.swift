import Foundation
import MeterDomain
import MeterPlatform

extension AppModel {
    /// Restores saved readings, applies the log setting, and starts refreshing. Call once.
    func start(archive: ReadingArchive?) async {
        var restored: Set<ProviderID> = []
        if let archive {
            let saved = await archive.load()
            // Settings can change while the file loads, so read them after it.
            let enabled = settings.settings.enabledProviders
            let kept = saved.filter { enabled.contains($0.key) }
            usage.restore(kept)
            restored = Set(kept.keys)
        }
        let current = settings.settings
        logFile.setEnabled(current.writesLogFile)
        let configuration = Self.refreshConfiguration(current)
        scheduler?.update(configuration)
        // A refresh reconciles first. Without one, still drop saved accounts whose login or
        // folder is gone, from local reads only.
        if !configuration.canRefresh, !restored.isEmpty {
            await usage.reconcile(restored)
        }
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
            logFile.setEnabled(new.writesLogFile)
        }
        if old.claude.isEnabled, !new.claude.isEnabled, claudeSettings?.isWorking == true {
            // A connect that finishes after Claude was turned off must store nothing.
            Task { await claudeSettings?.abandonConnect() }
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
        if old.claude.extraDirectories != new.claude.extraDirectories {
            Task { await claudeSettings?.reload() }
        }
        if old.codex.extraHomes != new.codex.extraHomes {
            scheduler?.refreshNow([.codex])
            Task { await codexSettings?.reload() }
        }
    }
}
