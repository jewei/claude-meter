import Foundation
import MeterDomain
import MeterPlatform
import Observation

/// The façade that views use: presentation models to render and actions to call.
///
/// Views never reach into the store, the scheduler, or a provider. They build a model for the
/// current time, render it, and call one of these actions.
@MainActor @Observable
public final class AppModel {
    public let settings: SettingsStore
    public let usage: UsageStore
    public let updater: any Updater
    /// The optional log file that the "Write a log file" setting turns on and off.
    public let logFile: LogFile

    /// The Claude connection and config dirs for Settings. Nil in previews.
    public let claudeSettings: ClaudeSettingsModel?
    /// Codex homes for Settings. Nil in previews.
    public let codexSettings: CodexSettingsModel?

    @ObservationIgnored let scheduler: RefreshScheduler?
    @ObservationIgnored let providers: LiveProviders?

    init(
        settings: SettingsStore, usage: UsageStore, scheduler: RefreshScheduler?,
        updater: any Updater, logFile: LogFile, providers: LiveProviders? = nil
    ) {
        self.settings = settings
        self.usage = usage
        self.scheduler = scheduler
        self.updater = updater
        self.logFile = logFile
        self.providers = providers
        self.claudeSettings = providers.map {
            ClaudeSettingsModel(settings: settings, usage: usage, provider: $0.claude)
        }
        self.codexSettings = providers.map {
            CodexSettingsModel(settings: settings, provider: $0.codex)
        }
        settings.onChange = { [weak self] old, new in
            self?.settingsDidChange(from: old, to: new)
        }
        claudeSettings?.onCredentialsChange = { [weak self] in
            self?.scheduler?.refreshNow([.claude])
        }
    }

    // MARK: - Models

    public func context(at now: Date) -> PresentationContext {
        PresentationContext(
            settings: settings.settings, readings: usage.readings, histories: usage.histories,
            refreshing: usage.refreshing, refreshingHistory: usage.refreshingHistory,
            restored: usage.restored, now: now, calendar: .current,
            isUpdateAvailable: updater.isUpdateAvailable)
    }

    public func menuBarModel(at now: Date) -> MenuBarModel {
        MenuBarModel(context(at: now))
    }

    public func popoverModel(at now: Date) -> PopoverModel {
        PopoverModel(context(at: now))
    }

    // MARK: - Popover actions

    /// Refreshes quota readings that are missing, failed, stale, or at least 60 s old, and
    /// token histories that are due (``UsageStore/historyNeedsRefresh(_:)``).
    public func popoverDidOpen() {
        scheduler?.popoverDidOpen()
    }

    /// Any path into Settings from the popover finishes the welcome and starts updates.
    public func completeOnboarding() {
        settings.update { $0.hasCompletedOnboarding = true }
    }

    public func toggleCard(_ id: CardID) {
        settings.update { settings in
            if settings.cards.expanded.contains(id) {
                settings.cards.expanded.remove(id)
            } else {
                settings.cards.expanded.insert(id)
            }
        }
    }

    /// Moves a card. A Claude or Codex card dropped first, also in place of the first card,
    /// becomes the main meter and is pinned; any other move keeps the main meter and the pins.
    /// Returns false only when the move is refused (``CardOrder/move(_:to:visible:saved:main:)``);
    /// a move that changes nothing returns true.
    @discardableResult
    public func moveCard(_ id: CardID, to index: Int, visible: [CardID]) -> Bool {
        let current = settings.settings
        let main = MainMeter(context(at: Date())).cardID
        let move: CardOrder.Move
        switch CardOrder.move(
            id, to: index, visible: visible, saved: current.cards.order, main: main)
        {
        case .moved(let result): move = result
        case .unchanged: return true
        case .refused: return false
        }
        settings.update { settings in
            settings.cards.order = move.order
            if let selection = move.newMain?.menuBarSelection {
                settings.menuBar.provider = selection.provider
                settings.menuBar.pinnedAccounts[selection.provider] = selection.account
            }
        }
        return true
    }

    /// Clears the saved order and both pins, so the nearest-limit account leads again.
    public func useAutomaticCardOrder() {
        settings.update { settings in
            settings.cards.order = []
            settings.menuBar.pinnedAccounts = [:]
        }
    }
}
