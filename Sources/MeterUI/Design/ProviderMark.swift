import AppKit
import MeterDomain
import SwiftUI

/// The provider's logo as a one-color mark, in ink unless `color` says otherwise. A provider
/// without a bundled logo falls back to a symbol.
struct ProviderMark: View {
    let provider: ProviderID
    var size: CGFloat = 15
    var color = Palette.ink

    var body: some View {
        Group {
            if let image = Self.image(for: provider) {
                Image(nsImage: image).renderingMode(.template).resizable()
            } else {
                Image(systemName: "atom").resizable()
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .foregroundStyle(color)
        .accessibilityLabel(provider.displayName)
    }

    @MainActor private static var cache: [ProviderID: NSImage] = [:]

    /// The bundled logo, loaded once. Nil for providers without one.
    @MainActor static func image(for provider: ProviderID) -> NSImage? {
        if let image = cache[provider] { return image }
        let name =
            switch provider {
            case .claude: "claude"
            case .codex: "codex"
            case .cursor: "cursor"
            case .grok: "grok"
            }
        guard let image = Bundle.module.image(forResource: name) else { return nil }
        image.isTemplate = true
        cache[provider] = image
        return image
    }
}
