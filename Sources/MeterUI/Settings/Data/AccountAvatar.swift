import MeterApp
import SwiftUI

/// A raised tile with the account's letter. The color comes from the account ID, so one
/// account keeps its color.
struct AccountAvatar: View {
    static let palette: [Color] = [
        Palette.Tile.sky, Palette.Tile.violet, Palette.Tile.orange, Palette.Tile.green,
        Color(nsColor: NSColor(hex: 0xFF7AA8)), Palette.Tile.teal,
        Color(nsColor: NSColor(hex: 0x7C83FF)), Palette.Tile.gold,
    ]

    let id: String
    let name: String
    var size: CGFloat = 34

    var body: some View {
        RaisedTile(fill: Self.color(for: id), size: size, radius: 11) {
            Text(DataSourceText.initial(name))
                .font(MeterFont.display(size * 0.5, .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    /// A stable palette color for an ID (djb2 hash).
    static func color(for id: String) -> Color {
        palette[paletteIndex(for: id)]
    }

    static func paletteIndex(for id: String) -> Int {
        var hash: UInt64 = 5_381
        for byte in id.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Int(hash % UInt64(palette.count))
    }
}
