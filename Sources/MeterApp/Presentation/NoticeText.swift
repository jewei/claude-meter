import Foundation
import MeterDomain

/// Text for an issue, with a countdown when the provider allows a retry later. The text
/// wraps, so the countdown has no-break spaces.
enum NoticeText {
    static func text(for issue: UsageIssue, now: Date) -> String {
        guard let retryAt = issue.retryAt,
            let countdown = Formatting.countdown(until: retryAt, now: now)
        else { return issue.message }
        return "\(issue.message) Retrying in \(countdown)."
    }
}
