import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI

struct AboutSettingsTab: View {
    /// Observed for the detected Claude Code version, which arrives from a poll.
    @ObservedObject var appState: AppState

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private let githubURL = URL(string: "https://github.com/jewei/claude-meter")!
    private let claudeCodeChangelogURL = URL(
        string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md")!

    /// Claude Code's version moved here from the popover footer, where it cost a
    /// line on every open to show something that changes a few times a month. The
    /// actionable half — "you're behind" — is kept and highlighted.
    private var claudeCodeVersion: String? { appState.snapshot?.source.cliVersion }

    private var claudeCodeOutdated: Bool {
        guard let current = claudeCodeVersion, let latest = appState.latestClaudeCodeVersion
        else { return false }
        return ClaudeCodeVersionCheck.isOutdated(current: current, latest: latest)
    }

    var body: some View {
        VStack(spacing: 18) {
            RaisedTile(fill: .pfEnergyFull, size: 104, radius: 26) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 54, weight: .black))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "FFE38A"), Color(hex: "FF9D0A")],
                            startPoint: .top, endPoint: .bottom))
            }
            .shadow(color: Color.pfEnergyFull.opacity(0.5), radius: 18, y: 6)
            .padding(.top, 4)

            Text("Claude Meter")
                .font(PFont.display(28, .bold))
                .foregroundStyle(Color.pfInk)

            Text("VERSION \(appVersion.uppercased())")
                .font(PFont.body(11, .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.pfHeroFullInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.pfHeroFullBG))

            if let cliVersion = claudeCodeVersion {
                Link(destination: claudeCodeChangelogURL) {
                    HStack(spacing: 5) {
                        Text("Claude Code v\(cliVersion)")
                            .font(PFont.body(11, .semibold))
                        if claudeCodeOutdated {
                            Text("update available")
                                .font(PFont.body(10, .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.pfEnergyLow.opacity(0.18)))
                        }
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(claudeCodeOutdated ? Color.pfEnergyLow : Color.pfInkMuted)
                }
                .buttonStyle(.plain)
                .help("Claude Code changelog")
            }

            Link(destination: githubURL) {
                HStack(spacing: 10) {
                    Image("GitHubMark")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                    Text("View on GitHub")
                        .font(PFont.display(15, .semibold))
                }
                .foregroundStyle(Color.pfInk)
                .padding(.horizontal, 28)
                .padding(.vertical, 13)
                .chunkyCard(radius: 16)
            }
            .buttonStyle(.plain)
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
            .foregroundStyle(Color.pfInkMuted.opacity(0.85))
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
