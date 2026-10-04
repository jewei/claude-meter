/// When the app keeps its Dock icon. Pure, so the rule has tests.
///
/// While Settings is open the app uses the regular activation policy: a Dock icon, a menu
/// bar, and Command-Tab. It goes back to an accessory when the last titled window closes, so
/// Sparkle's update window keeps the Dock icon after Settings closes.
enum DockIconPolicy {
    /// One window of the app, as the activation policy sees it.
    struct Window: Equatable {
        var isTitled: Bool
        /// On screen or in the Dock.
        var isOpen: Bool
        var isClosing = false
    }

    /// Whether the app keeps the regular activation policy. It does while any titled window
    /// other than the closing one stays open, such as Sparkle's update window.
    static func keepsDockIcon(_ windows: [Window]) -> Bool {
        windows.contains { $0.isTitled && $0.isOpen && !$0.isClosing }
    }
}
