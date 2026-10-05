import MeterApp
import MeterDomain
import SwiftUI

/// One report section as a card of label and value rows. Values can be selected.
struct DiagnosticsSectionView: View {
    let section: DiagnosticsReport.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(text: section.title)
            SettingsCard(spacing: 8) {
                ForEach(Array(section.facts.enumerated()), id: \.offset) { _, fact in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(fact.label)
                            .font(MeterFont.body(12, .bold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 120, alignment: .leading)
                        Text(fact.value)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.inkMuted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
