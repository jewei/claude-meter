import SwiftUI

/// One data source: a tile, title, subtitle, and switch. When the source is on, its own
/// controls follow below a divider at the full card width.
struct DataSourceCard<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @Binding var isEnabled: Bool
    /// False when the source has no controls of its own here.
    var showsContent = true
    @ViewBuilder let content: Content

    var body: some View {
        SettingsCard(spacing: 14) {
            SettingsRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
                MeterSwitch(label: title, isOn: $isEnabled)
            }
            if isEnabled, showsContent {
                CardDivider()
                content
            }
        }
    }
}

extension DataSourceCard where Content == EmptyView {
    init(
        symbol: String, tint: Color, title: String, subtitle: String, isEnabled: Binding<Bool>
    ) {
        self.init(
            symbol: symbol, tint: tint, title: title, subtitle: subtitle, isEnabled: isEnabled,
            showsContent: false
        ) { EmptyView() }
    }
}
