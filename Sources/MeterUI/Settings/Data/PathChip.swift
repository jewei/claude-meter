import SwiftUI

/// A folder path in a small chip, shortened with `~`. The tooltip and the accessibility value
/// give the full path.
struct PathChip: View {
    let path: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill").font(.system(size: 9, weight: .bold))
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Palette.inkMuted)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Palette.track.opacity(0.8)))
        .help(path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folder")
        .accessibilityValue(path)
    }
}
