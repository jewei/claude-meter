import AppKit
import SwiftUI

/// Settings > About: the icon, name, version, project link, license, credits, and the
/// trademark disclaimer.
struct AboutSettingsView: View {
    static let repository = URL(string: "https://github.com/jewei/claude-meter")!

    var body: some View {
        VStack(spacing: 14) {
            RaisedTile(fill: Palette.energyFull, size: 104, radius: 26) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 54, weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(nsColor: NSColor(hex: 0xFFE38A)), Palette.Tile.orange],
                            startPoint: .top, endPoint: .bottom))
            }
            .shadow(color: Palette.energyFull.opacity(0.16), radius: 14, y: 6)
            .padding(.top, 4)
            .accessibilityHidden(true)
            Text("Claude Meter")
                .font(MeterFont.display(28, .bold))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text("A little clarity for your daily energy.")
                .font(MeterFont.body(14, .semibold))
                .foregroundStyle(Palette.inkMuted)
            Text("VERSION \(AppVersion.current.text.uppercased())")
                .font(MeterFont.body(11, .extraBold))
                .tracking(1.2)
                .foregroundStyle(Palette.heroFull.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Palette.heroFull.background))
                .accessibilityLabel("Version \(AppVersion.current.text)")
            Link(destination: Self.repository) {
                HStack(spacing: 10) {
                    githubMark
                    Text("View on GitHub").font(MeterFont.display(15, .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.inkMuted)
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 28)
                .padding(.vertical, 13)
            }
            .buttonStyle(QuietButtonStyle(radius: 16, surface: .chunky))
            .help(Self.repository.absoluteString)
            .padding(.top, 2)
            Rectangle().fill(Palette.cardBorder).frame(height: 1).padding(.vertical, 4)
            Text("© JEWEI MAK · MIT LICENSE")
                .font(MeterFont.body(12, .extraBold))
                .tracking(1)
                .foregroundStyle(Palette.inkMuted)
            Group {
                Text("Fredoka and Nunito fonts under the SIL Open Font License 1.1.")
                Text(
                    "An independent community project. Not affiliated with or endorsed by Anthropic. \u{201C}Claude\u{201D} is a trademark of Anthropic."
                )
            }
            .font(MeterFont.body(12, .semibold))
            .foregroundStyle(Palette.inkMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
        }
        .padding(28)
        .frame(maxWidth: 470)
        .chunkyCard(radius: 22)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var githubMark: some View {
        if let image = Bundle.module.image(forResource: "github") {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }
}
