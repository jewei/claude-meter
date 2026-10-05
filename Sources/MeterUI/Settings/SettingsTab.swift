import SwiftUI

/// The four Settings pages, in tab order. Command-1 to Command-4 select them.
enum SettingsTab: Int, CaseIterable, Identifiable {
    case data, appearance, advanced, about

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .data: "Data"
        case .appearance: "Appearance"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .data: "cylinder.split.1x2"
        case .appearance: "paintpalette.fill"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    /// `1` for the first tab, used with Command.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String(rawValue + 1)))
    }
}
