import AppKit
import SwiftUI

// MARK: - Severity colors from DESIGN.md
extension Color {
    static let cmNormal = Color(hex: "4be257")
    static let cmWarning = Color(hex: "fdbb2c")
    static let cmCritical = Color(hex: "ff5f56")
    static let cmBackground = Color(hex: "10131b")
}

/// Caution/warning accent — a deep amber, friendlier than system `.orange` on the
/// bright popover material while staying distinct from the critical red, and
/// adaptive for light/dark. Computed once.
private let cmWarningTint = Color(light: "B45309", dark: "F59E0B")

extension ShapeStyle where Self == Color {
    /// Usable in both `.foregroundStyle(.warningTint)` / `.fill(.warningTint)` and
    /// `Color`-typed contexts (`return .warningTint`), like the system `.orange`.
    static var warningTint: Color { cmWarningTint }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Appearance-adaptive color from two hex values (light vs. dark mode).
    init(light: String, dark: String) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(Color(hex: isDark ? dark : light))
            }
        )
    }
}
