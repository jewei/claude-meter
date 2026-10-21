import AppKit
import SwiftUI

/// Draws ``MenuBarLabel`` as the image of the status button.
///
/// The system dims a status button's own image on the menu bar of an inactive display, as it
/// dims every other item. It does not dim views added to the button, so the label is an image,
/// not a hosted view. AppKit can draw the image on any thread and in the appearance of each
/// menu bar, so the label is drawn ahead of time for both appearances and for each screen
/// scale, and the drawing handler only picks one.
enum MenuBarImage {
    private struct Render: Sendable {
        let isDark: Bool
        let scale: CGFloat
        let image: CGImage
    }

    /// The label with `padding` on each side, centered in `height`. Nil when nothing renders.
    @MainActor static func make(
        _ label: MenuBarLabel, padding: CGFloat, height: CGFloat, scales: Set<CGFloat>
    ) -> NSImage? {
        var width: CGFloat = 0
        ImageRenderer(content: label).render { size, _ in width = size.width }
        // A whole number of points keeps every scale the same size and the text on the
        // pixel grid.
        let size = CGSize(width: ceil(width) + 2 * padding, height: height)
        let content = label.frame(width: size.width, height: size.height)
        var renders: [Render] = []
        for isDark in [false, true] {
            for scale in scales {
                let renderer = ImageRenderer(
                    content: content.environment(\.colorScheme, isDark ? .dark : .light))
                renderer.scale = scale
                guard let image = renderer.cgImage else { continue }
                renders.append(Render(isDark: isDark, scale: scale, image: image))
            }
        }
        guard !renders.isEmpty else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let isDark =
                NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let deviceScale = abs(context.userSpaceToDeviceSpaceTransform.a)
            let matching = renders.filter { $0.isDark == isDark }.sorted { $0.scale < $1.scale }
            guard let render = matching.first(where: { $0.scale >= deviceScale }) ?? matching.last
            else { return false }
            context.draw(render.image, in: rect)
            return true
        }
        // A cached drawing would keep the first appearance on every menu bar.
        image.cacheMode = .never
        return image
    }
}
