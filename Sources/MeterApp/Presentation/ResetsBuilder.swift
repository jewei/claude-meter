import Foundation
import MeterDomain

/// Builds the "Usage limit resets" section.
enum ResetsBuilder {
    /// `calendar` sets the time zone and locale of the exact expiry in the tooltip; card
    /// builders pass the context's calendar.
    static func model(
        _ allowance: ResetAllowance?, now: Date, calendar: Calendar = .current
    ) -> ResetsModel {
        guard let allowance else {
            return ResetsModel(countText: "Not reported", rows: [], note: nil, summary: nil)
        }
        let style = Date.FormatStyle(
            date: .abbreviated, time: .shortened,
            locale: calendar.locale ?? Formatting.numberLocale,
            calendar: calendar, timeZone: calendar.timeZone)
        let rows =
            allowance.available == 0
            ? []
            : allowance.resets.map { reset in
                ResetsModel.Row(
                    title: reset.title,
                    expiryText: expiryText(reset.expiresAt, now: now),
                    help: reset.expiresAt.map { "Expires \($0.formatted(style))" }
                        ?? "Expiry date not provided")
            }
        let note: String? =
            if allowance.available == 0 {
                nil
            } else if rows.isEmpty {
                "Expiry details unavailable"
            } else if rows.count < allowance.available {
                "Expiry details shown for \(rows.count) of \(allowance.available) resets"
            } else {
                nil
            }
        let count = allowance.available
        return ResetsModel(
            countText: "\(count) available", rows: rows, note: note,
            summary: count == 0
                ? nil : "\(count) usage \(count == 1 ? "reset" : "resets") available")
    }

    private static func expiryText(_ date: Date?, now: Date) -> String {
        guard let date else { return "Expiry date not provided" }
        guard let countdown = Countdown.text(until: date, now: now) else { return "Expired" }
        return "Expires in \(countdown)"
    }
}
