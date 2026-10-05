import SwiftUI

/// A rounded square with a brand fill and a white glyph, used for the header icon and the
/// Settings tiles. A 3 pt dark band inside the bottom edge gives it depth.
struct RaisedTile<Content: View>: View {
    var fill: Color
    var size: CGFloat
    var radius: CGFloat = 11
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .frame(width: size, height: size)
            .background(fill)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .clear], startPoint: .top,
                        endPoint: .bottom),
                    lineWidth: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.13)).frame(height: 3)
            }
            .clipShape(shape)
    }
}

extension RaisedTile where Content == TileGlyph {
    /// A tile with one white SF Symbol. The glyph defaults to 17 pt on a 40 pt tile.
    init(
        symbol: String, fill: Color, size: CGFloat = 40, radius: CGFloat = 11,
        glyphSize: CGFloat? = nil
    ) {
        self.init(fill: fill, size: size, radius: radius) {
            TileGlyph(symbol: symbol, size: glyphSize ?? (size * 17 / 40).rounded())
        }
    }
}

/// The white SF Symbol inside a ``RaisedTile``.
struct TileGlyph: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
}
