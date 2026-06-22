import SwiftUI

// MARK: - Severity colors from DESIGN.md
extension Color {
    static let cmNormal   = Color(hex: "4be257")
    static let cmWarning  = Color(hex: "fdbb2c")
    static let cmCritical = Color(hex: "ff5f56")
    static let cmBackground = Color(hex: "10131b")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >>  8) & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
