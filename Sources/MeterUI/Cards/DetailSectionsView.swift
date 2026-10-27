import MeterApp
import SwiftUI

/// A card's detail sections in model order. A divider opens each section, 12 pt from the
/// content on either side.
struct DetailSectionsView: View {
    let sections: [DetailSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                CardDivider()
                switch section {
                case .limits(let gauges):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(gauges.enumerated()), id: \.offset) { _, gauge in
                            LimitRow(gauge: gauge)
                        }
                    }
                case .usageBars(let gauges):
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(gauges.enumerated()), id: \.offset) { _, gauge in
                            UsageBarRow(gauge: gauge)
                        }
                    }
                case .resets(let resets):
                    ResetsSectionView(resets: resets)
                case .tokens(let tokens):
                    TokensSectionView(tokens: tokens)
                }
            }
        }
    }
}
