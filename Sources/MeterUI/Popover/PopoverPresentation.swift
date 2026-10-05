import Foundation
import Observation

/// The panel state that the popover views read.
@MainActor @Observable final class PopoverPresentation {
    /// The panel is on screen. The clock ticks and animations run only while it is.
    var isVisible = false
    /// The content is taller than the body cap, so the body scrolls.
    var scrolls = false
}
