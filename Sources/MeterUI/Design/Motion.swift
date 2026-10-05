import SwiftUI

/// Every animation in the app. Callers pass Reduce Motion, which turns each one off.
enum Motion {
    /// Card expansion and collapse, the chevron, list reordering, and the panel height.
    static let disclosureDuration: TimeInterval = 0.18
    /// One critical pulse cycle of the menu-bar dot.
    static let pulsePeriod: TimeInterval = 1.2
    static let pulseCount = 3
    /// The pulse redraws at most this often.
    static let pulseFrameInterval: TimeInterval = 1.0 / 12
    /// One turn of the loading arrow.
    static let spinPeriod: TimeInterval = 1
    /// The loading arrow redraws at most this often, not at the display refresh rate.
    static let spinFrameInterval: TimeInterval = 1.0 / 30

    static func disclosure(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: disclosureDuration)
    }

    /// Ring arc length and bar fill width.
    static func value(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.4)
    }

    /// Severity and hero colors.
    static func tone(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.3)
    }

    /// The raised button press.
    static func press(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.85)
    }
}

extension EnvironmentValues {
    /// Whether the popover is on screen. Continuous animations and clocks run only while it
    /// is, because a hidden panel keeps its views alive.
    @Entry var popoverIsVisible = true

    /// Draws native controls (switches, spinners) as static shapes and lays out scroll views
    /// at their full height, so `ImageRenderer` can draw a whole screen. Tests only.
    @Entry var rendersStatically = false
}
