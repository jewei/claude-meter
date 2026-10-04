import SwiftUI

/// A spinner over a short message, such as "Checking your tanks…".
struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Spinner()
            Text(message)
                .font(MeterFont.body(13, .semibold))
                .foregroundStyle(Palette.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 22)
        .accessibilityElement(children: .combine)
    }
}
