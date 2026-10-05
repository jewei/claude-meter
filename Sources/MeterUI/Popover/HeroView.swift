import MeterApp
import SwiftUI

/// The summary for the main meter: a mascot, a headline, and a subline on a surface whose
/// colors follow the tone. VoiceOver reads it as one element: "headline. subline".
struct HeroView: View {
    let hero: HeroModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.popoverIsVisible) private var isVisible

    var body: some View {
        let colors = hero.tone.colors
        HStack(spacing: 12) {
            Text(hero.emoji)
                .font(.system(size: 24))
                .frame(width: 46, height: 46)
                .background(Circle().fill(Palette.card))
                .overlay(Circle().strokeBorder(colors.border, lineWidth: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text(hero.title)
                    .font(MeterFont.display(18, .semibold))
                    .foregroundStyle(colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(hero.subtitle)
                    .font(MeterFont.body(12, .bold))
                    .monospacedDigit()
                    .foregroundStyle(colors.subink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard(fill: colors.background, border: colors.border)
        .animation(Motion.tone(reduceMotion: reduceMotion || !isVisible), value: hero.tone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hero.accessibilityLabel)
    }
}
