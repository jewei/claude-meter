import Foundation
import MeterDomain

/// The title and body of each alert. Short sentences that say what happens next. Numbers
/// follow the meter mode, as on the cards.
enum AlertText {
    static func title(_ kind: Alert.Kind) -> String {
        switch kind {
        case .lowEnergy: "Low energy"
        case .runOut: "Runs out before the reset"
        case .refill: "Energy refilled"
        }
    }

    /// `Claude Work: Session has 4% left. It refills in 1h 20m.`
    static func body(
        _ kind: Alert.Kind, window: QuotaWindow, account: AccountUsage, provider: ProviderID,
        runOut: Date?, context: PresentationContext
    ) -> String {
        let showsUsed = context.showsUsed
        let value = Formatting.percent(window, showsUsed: showsUsed)
        let sentence: String
        switch kind {
        case .lowEnergy:
            let amount = showsUsed ? "is \(value) used" : "has \(value) left"
            sentence = "\(window.title) \(amount).\(refill(window, now: context.now))"
        case .runOut:
            let when = runOut.map { PaceText.when($0, now: context.now) } ?? "now"
            sentence = "\(window.title) runs out \(when).\(refill(window, now: context.now))"
        case .refill:
            sentence = "\(window.title) refilled. \(value) \(showsUsed ? "used" : "left")."
        }
        return "\(name(account, provider: provider)): \(sentence)"
    }

    /// ` It refills in 1h 20m.`, or nothing without a future reset.
    private static func refill(_ window: QuotaWindow, now: Date) -> String {
        guard let date = window.resetsAt, let phrase = Countdown.phrase(until: date, now: now)
        else { return "" }
        return " It refills \(phrase)."
    }

    /// `Claude Work`, or `Cursor` for an account named after its provider. A display name can
    /// be an email, and the text leaves the app, so it goes through ``Redactor``.
    private static func name(_ account: AccountUsage, provider: ProviderID) -> String {
        let name =
            account.name == provider.displayName
            ? account.name : "\(provider.displayName) \(account.name)"
        return Redactor.redact(name)
    }
}
