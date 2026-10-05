import Observation

/// The selected Settings tab. The window controller keeps it, so Settings opens again on the
/// tab that the user left, and the app menu can open About.
@MainActor @Observable final class SettingsNavigation {
    var tab: SettingsTab

    init(tab: SettingsTab = .data) {
        self.tab = tab
    }
}
