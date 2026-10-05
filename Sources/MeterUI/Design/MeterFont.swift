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
        case semibold, bold

        var face: String {
            switch self {
            case .semibold: "Fredoka-SemiBold"
            case .bold: "Fredoka-Bold"
            }
        }

        var systemWeight: Font.Weight {
            switch self {
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

    /// Fredoka at a fixed size. Its digits are not all the same width, and it has no tabular
    /// digits, so `.monospacedDigit()` does nothing on it. A changing number in it takes a
    /// fixed width instead (``SwiftUI/View/fixedNumberWidth(fitting:font:alignment:)``).
    static func display(_ size: CGFloat, _ weight: DisplayWeight = .semibold) -> Font {
        font(weight.face, size: size, fallback: weight.systemWeight)
    }

    /// Nunito at a fixed size. Its digits are all the same width, so `.monospacedDigit()`
    /// keeps a changing number in it at one width.
    static func body(_ size: CGFloat, _ weight: BodyWeight = .bold) -> Font {
        font(weight.face, size: size, fallback: weight.systemWeight)
    }

    /// The display face as an `NSFont`, for measuring text: the system rounded font of the
    /// same weight when the face is not available, as ``display(_:_:)`` draws it.
    private static func displayFont(_ size: CGFloat, _ weight: DisplayWeight) -> NSFont {
        if availableFaces.contains(weight.face), let font = NSFont(name: weight.face, size: size) {
            return font
        }
        let system = NSFont.systemFont(ofSize: size, weight: weight == .bold ? .bold : .semibold)
        guard let rounded = system.fontDescriptor.withDesign(.rounded) else { return system }
        return NSFont(descriptor: rounded, size: size) ?? system
    }

    /// The digit with the widest advance in the display face of `weight`. Advances scale with
    /// the size, so one measure serves every size.
    static func widestDigit(_ weight: DisplayWeight) -> Character {
        if let digit = widestDigits[weight] { return digit }
        let font = displayFont(100, weight)
        let digit =
            Array("0123456789").max { first, second in
                advance(of: first, in: font) < advance(of: second, in: font)
            } ?? "0"
        widestDigits[weight] = digit
        return digit
    }

    private static var widestDigits: [DisplayWeight: Character] = [:]

    private static func advance(of character: Character, in font: NSFont) -> CGFloat {
        NSAttributedString(string: String(character), attributes: [.font: font]).size().width
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
            [DisplayWeight.semibold, .bold].map(\.face)
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
