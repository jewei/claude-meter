import SwiftUI

/// A 28 pt trash button that removes one folder from a list.
struct RemoveButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.energyEmptyInk)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(QuietButtonStyle(radius: 8))
        .accessibilityLabel("Remove \(name)")
        .help("Remove \(name) from Claude Meter. The folder stays on disk.")
    }
}
