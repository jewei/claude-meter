import ClaudeMeterCore
import SwiftUI

struct TokenUsageRows: View {
    let provider: ProviderID
    let reading: ReadingState<TokenUsageSnapshot>?
    let isRefreshing: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().overlay(Color.pfCardBorder)
            HStack(alignment: .firstTextBaseline) {
                Text("Tokens used")
                    .font(PFont.body(11, .bold))
                    .foregroundStyle(Color.pfInk)
                Spacer()
                Text(provider == .cursor ? "Account usage" : "This Mac")
                    .font(PFont.body(10, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
            ForEach(TokenUsagePeriod.allCases, id: \.self) { period in
                let count = reading?.value?.tokens(for: period, asOf: now)
                HStack {
                    Text(period.rawValue)
                        .font(PFont.body(11, .semibold))
                    Spacer()
                    Text(Self.formatted(count))
                        .font(PFont.body(11, .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.pfInk)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(period.rawValue)
                .accessibilityValue(count.map { "\($0.formatted()) tokens" } ?? "Unavailable")
                .help(
                    count.map { "\($0.formatted()) tokens, including cache tokens" }
                        ?? "Token count unavailable")
            }
            if let status {
                Text(status)
                    .font(PFont.body(10, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(
            provider == .cursor
                ? "Token records reported by Cursor for this account."
                : "All retained local sessions for this provider, including earlier logins. The same total appears on each of its account cards. Other devices are not included."
        )
    }

    private var status: String? {
        if let error = reading?.error { return error }
        guard let value = reading?.value else {
            return isRefreshing ? "Reading token usage…" : "Token usage unavailable"
        }
        if value.isPartial { return "Partial history · some records could not be counted" }
        if !value.hasRecords { return "No local token records" }
        if reading?.isStale == true
            || MeterSettings.isSnapshotStale(lastPollAt: value.observedAt, now: now)
            || value.timeZoneID != Calendar.current.timeZone.identifier
            || !Calendar.current.isDate(value.observedAt, inSameDayAs: now)
        {
            return "Token data may be stale"
        }
        return nil
    }

    static func formatted(_ count: Int64?) -> String {
        guard let count else { return "—" }
        let value = count.formatted(
            .number.notation(.compactName).precision(.fractionLength(0...1)))
        return "\(value) \(count == 1 ? "token" : "tokens")"
    }
}
