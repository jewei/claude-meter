import Foundation
import MeterDomain

/// A full-size popover message.
public struct StatusScreen: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case getStarted
        case openSettings
    }

    public let emoji: String
    public let title: String
    public let message: String
    public let action: Action
    public let actionTitle: String

    static let onboarding = StatusScreen(
        emoji: "🚀", title: "Welcome to Claude Meter",
        message: "Connect a data source to start your engines.", action: .getStarted,
        actionTitle: "Get started →")

    static let paused = StatusScreen(
        emoji: "😴", title: "Paused", message: "Resume updates in Settings when you are ready.",
        action: .openSettings, actionTitle: "Open Settings")

    static let noSources = StatusScreen(
        emoji: "🔌", title: "No data sources on",
        message: "Turn on at least one source in Settings > Data.", action: .openSettings,
        actionTitle: "Open Settings")

    static func error(_ provider: ProviderID, message: String) -> StatusScreen {
        StatusScreen(
            emoji: "⚠️", title: "Couldn't read \(provider.displayName)", message: message,
            action: .openSettings, actionTitle: "Open Settings")
    }

    static func setup(_ enabled: Set<ProviderID>) -> StatusScreen {
        let message: String =
            switch enabled {
            case [.codex]:
                "Install Codex or run `codex login` so Claude Meter can read Codex usage."
            case [.cursor]: "Sign in to the Cursor app so Claude Meter can read your billing usage."
            case [.grok]:
                "Install Grok Build or run `grok login` so Claude Meter can read Grok usage."
            case [.claude]: "Connect Claude in Settings to read your usage."
            default: "Sign in to the enabled sources, or connect Claude in Settings."
            }
        return StatusScreen(
            emoji: "🪫", title: "No usage yet", message: message, action: .openSettings,
            actionTitle: "Open Settings")
    }
}
