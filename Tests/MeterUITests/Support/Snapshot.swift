import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MeterUI

/// Renders views to PNG files for visual review.
///
/// Nothing is written unless `CLAUDE_METER_RENDER_DIR` names a folder, so a normal test run
/// only checks that each view renders. `ImageRenderer` needs no display.
@MainActor enum Snapshot {
    static let directory: URL? = ProcessInfo.processInfo.environment["CLAUDE_METER_RENDER_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// Renders `view` in light and dark appearance as `<name>-light.png` and
    /// `<name>-dark.png`, on the popover background.
    static func render(
        _ name: String, background: Color = Palette.popover, padding: CGFloat = 0,
        @ViewBuilder _ view: () -> some View
    ) {
        let content = view()
        for scheme in [ColorScheme.light, .dark] {
            let framed =
                content
                .padding(padding)
                .background(background)
                .environment(\.colorScheme, scheme)
                .environment(\.rendersStatically, true)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            guard let image = renderer.cgImage else {
                Issue.record("\(name) did not render")
                return
            }
            #expect(image.width > 0 && image.height > 0)
            guard let directory else { continue }
            let suffix = scheme == .dark ? "dark" : "light"
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try data?.write(to: directory.appending(path: "\(name)-\(suffix).png"))
            } catch {
                Issue.record("Could not write \(name): \(error)")
            }
        }
    }
}
