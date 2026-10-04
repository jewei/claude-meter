import AppKit
import CoreText
import SwiftUI

/// The two type families of the design system.
///
/// Fredoka (display) sets headings, numbers, avatars, and plan badges. Nunito (body) sets
/// labels and captions. Both ship in `Resources/Fonts` and are registered for this process
/// on first use. A face that is not available falls back to the system rounded font of the
/// same weight, so the layout never depends on registration.
@MainActor enum MeterFont {
    enum DisplayWeight: Sendable {
        case regular, semibold, bold

        var face: String {
            switch self {
            case .regular: "Fredoka-Regular"
            case .semibold: "Fredoka-SemiBold"
            case .bold: "Fredoka-Bold"
            }
        }

        var systemWeight: Font.Weight {
            switch self {
            case .regular: .regular
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    enum BodyWeight: Sendable {
        case semibold, bold, extraBold

        var face: String {
            switch self {
            case .semibold: "Nunito-SemiBold"
            case .bold: "Nunito-Bold"
            case .extraBold: "Nunito-ExtraBold"
            }
        }

        var systemWeight: Font.Weight {
            switch self {
            case .semibold: .semibold
            case .bold: .bold
            case .extraBold: .heavy
            }
        }
    }

    /// Fredoka at a fixed size. Changing numbers also need `.monospacedDigit()`.
    static func display(_ size: CGFloat, _ weight: DisplayWeight = .semibold) -> Font {
        font(weight.face, size: size, fallback: weight.systemWeight)
    }

    /// Nunito at a fixed size.
    static func body(_ size: CGFloat, _ weight: BodyWeight = .bold) -> Font {
        font(weight.face, size: size, fallback: weight.systemWeight)
    }

    /// Registers the bundled TTFs. The app calls it at launch; later calls do nothing.
    static func registerBundledFonts() {
        _ = availableFaces
    }

    /// The bundled faces that are usable in this process.
    static let availableFaces: Set<String> = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts")
        if let urls, !urls.isEmpty {
            // A nil handler makes the call synchronous: the faces are usable when it returns.
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        }
        let faces =
            [DisplayWeight.regular, .semibold, .bold].map(\.face)
            + [BodyWeight.semibold, .bold, .extraBold].map(\.face)
        return Set(faces.filter { NSFont(name: $0, size: 12) != nil })
    }()

    private static func font(_ face: String, size: CGFloat, fallback: Font.Weight) -> Font {
        guard availableFaces.contains(face) else {
            return .system(size: size, weight: fallback, design: .rounded)
        }
        return .custom(face, fixedSize: size)
    }
}
