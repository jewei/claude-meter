import MeterDomain
import SwiftUI

/// One data source: a tile with the provider's logo, title, subtitle, and switch. When the source is on, its own
/// controls follow below a divider at the full card width.
struct DataSourceCard<Content: View>: View {
    let provider: ProviderID
    let tint: Color
    let title: String
    let subtitle: String
    @Binding var isEnabled: Bool
    /// False when the source has no controls of its own here.
    var showsContent = true
    @ViewBuilder let content: Content

    var body: some View {
        SettingsCard(spacing: 14) {
            SettingsRow(
                icon: RaisedTile(fill: tint, size: 40) {
                    ProviderMark(provider: provider, size: 20, color: .white)
                        .accessibilityHidden(true)
                },
                title: title, subtitle: subtitle
            ) {
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
        provider: ProviderID, tint: Color, title: String, subtitle: String,
        isEnabled: Binding<Bool>
    ) {
        self.init(
            provider: provider, tint: tint, title: title, subtitle: subtitle, isEnabled: isEnabled,
            showsContent: false
        ) { EmptyView() }
    }
}
