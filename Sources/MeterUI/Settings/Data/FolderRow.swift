import SwiftUI

/// The shared layout of a config-dir or Codex-home row: avatar, name field, details, and
/// trailing controls on a soft rounded surface.
struct FolderRow<Details: View, Controls: View>: View {
    let id: String
    let name: String?
    let defaultName: String
    let rename: (String) -> Void
    @ViewBuilder let details: Details
    @ViewBuilder let controls: Controls

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            AccountAvatar(id: id, name: name ?? defaultName)
            VStack(alignment: .leading, spacing: 7) {
                DisplayNameField(name: name, placeholder: defaultName, save: rename)
                details
            }
            controls.frame(minHeight: 30)
        }
        .padding(10)
        .background(shape.fill(Palette.popover))
        .overlay(shape.strokeBorder(Palette.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name ?? defaultName)
    }
}
