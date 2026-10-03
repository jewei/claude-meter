import SwiftUI

struct AboutSettingsTab: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private let githubURL = URL(string: "https://github.com/jewei/claude-meter")!

    var body: some View {
        VStack(spacing: 16) {
            RaisedTile(fill: .pfEnergyFull, size: 104, radius: 26) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 54, weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "FFE38A"), Color(hex: "FF9D0A")],
                            startPoint: .top, endPoint: .bottom))
            }
            .shadow(color: Color.pfEnergyFull.opacity(0.16), radius: 14, y: 6)
            .padding(.top, 4)

            Text("Claude Meter")
                .font(PFont.display(28, .bold))
                .foregroundStyle(Color.pfInk)

            Text("A little clarity for your daily energy.")
                .font(PFont.body(14, .semibold))
                .foregroundStyle(Color.pfInkMuted)
                .multilineTextAlignment(.center)

            Text("VERSION \(appVersion.uppercased())")
                .font(PFont.body(11, .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.pfHeroFullInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.pfHeroFullBG))

            Link(destination: githubURL) {
                HStack(spacing: 10) {
                    Image("GitHubMark")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Text("View on GitHub")
                        .font(PFont.display(15, .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.pfInkMuted)
                }
                .foregroundStyle(Color.pfInk)
                .padding(.horizontal, 28)
                .padding(.vertical, 13)
                .chunkyCard(radius: 16)
            }
            .buttonStyle(QuietButtonStyle(radius: 16))
            .padding(.top, 2)

            Rectangle()
                .fill(Color.pfCardBorder)
                .frame(height: 1)
                .padding(.horizontal, 2)
                .padding(.vertical, 4)

            Text("© JEWEI MAK")
                .font(PFont.body(12, .heavy))
                .tracking(1.0)
                .foregroundStyle(Color.pfInkMuted)

            Text(
                "An independent community project. Not affiliated with or endorsed by Anthropic. \u{201C}Claude\u{201D} is a trademark of Anthropic."
            )
            .font(PFont.body(12, .semibold))
            .foregroundStyle(Color.pfInkMuted)
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
}
