import AppKit
import MeterApp
import SwiftUI

/// Draws ``MenuBarLabel`` for the status button: the ink as the button's template image, and
/// the red "0" pill as a colored image on top.
///
/// The system dims a button's template image on the menu bar of an inactive display as much as
/// every other item. It dims a colored image only a little, and never dims views added to the
/// button. So everything is a template except the pill, the one alert that keeps its color.
/// Both images have the same size, so the pill lines up with the bolt.
struct MenuBarImage {
    /// The icon, the number, and the stale dot, as a template. Paused and not set up draw it in the secondary
    /// color, which a template keeps as a lower opacity.
    let ink: NSImage
    /// The red "0" pill. Nil unless no energy is left.
    let badge: NSImage?

    private struct Render: Sendable {
        let isDark: Bool
        let scale: CGFloat
        let image: CGImage
    }

    /// The label with `padding` on each side, centered in `height`. Nil when nothing renders.
    @MainActor static func make(
        _ label: MenuBarLabel, padding: CGFloat, height: CGFloat, scales: Set<CGFloat>
    ) -> MenuBarImage? {
        var width: CGFloat = 0
        ImageRenderer(content: label).render { size, _ in width = size.width }
        // A whole number of points keeps every scale the same size and the text on the
        // pixel grid.
        let size = CGSize(width: ceil(width) + 2 * padding, height: height)
        func layer(_ layer: MenuBarLabel.Layer) -> some View {
            var label = label
            label.layer = layer
            return label.frame(width: size.width, height: size.height)
        }
        guard let ink = template(layer(.ink), size: size, scales: scales) else { return nil }
        let badge =
            label.model.icon == .bolt(.exhausted)
            ? colored(layer(.badge), size: size, scales: scales) : nil
        return MenuBarImage(ink: ink, badge: badge)
    }

    /// One bitmap for each scale. The template uses only the alpha of the dark ink.
    @MainActor private static func template(
        _ content: some View, size: CGSize, scales: Set<CGFloat>
    ) -> NSImage? {
        let image = NSImage(size: size)
        for scale in scales {
            let renderer = ImageRenderer(content: content.environment(\.colorScheme, .light))
            renderer.scale = scale
            guard let cgImage = renderer.cgImage else { continue }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            bitmap.size = size
            image.addRepresentation(bitmap)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }

    /// Drawn ahead of time for both appearances and each scale, because AppKit can draw the
    /// image on any thread and in the appearance of each menu bar. The drawing handler only
    /// picks one.
    @MainActor private static func colored(
        _ content: some View, size: CGSize, scales: Set<CGFloat>
    ) -> NSImage? {
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
