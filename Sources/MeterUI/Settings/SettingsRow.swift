import SwiftUI

/// A 40 pt icon tile, a title, a subtitle, and a trailing control.
struct SettingsRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    var subtitleColor: Color = Palette.inkMuted
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            RaisedTile(symbol: symbol, fill: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MeterFont.display(16, .semibold))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(MeterFont.body(12, .semibold))
                        .foregroundStyle(subtitleColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}
