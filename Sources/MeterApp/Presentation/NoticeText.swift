import Foundation
import MeterDomain

/// Text for an issue, with a countdown when the provider allows a retry later.
enum NoticeText {
    static func text(for issue: UsageIssue, now: Date) -> String {
        guard let retryAt = issue.retryAt, let countdown = Countdown.text(until: retryAt, now: now)
        else { return issue.message }
        return "\(issue.message) Retrying in \(countdown)."
    }
}
