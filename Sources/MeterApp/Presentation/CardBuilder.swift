import Foundation
import MeterDomain

/// Builds the card for every account, in automatic order.
struct CardBuilder {
    let context: PresentationContext
    let meter: MainMeter

    private var gauges: GaugeBuilder { GaugeBuilder(context: context) }

    /// Automatic order: the main provider's accounts with the selected one first, then Claude
    /// extra usage, then the other main-capable provider, then Cursor and Grok.
    func cards() -> [CardModel] {
        let other: ProviderID = meter.provider == .claude ? .codex : .claude
        var cards = accountCards(meter.provider, selectedFirst: true)
        if let extra = extraUsageCard() { cards.append(extra) }
        cards += accountCards(other, selectedFirst: false)
        cards += accountCards(.cursor, selectedFirst: false)
        cards += accountCards(.grok, selectedFirst: false)
        return cards
    }

    private func accountCards(_ provider: ProviderID, selectedFirst: Bool) -> [CardModel] {
        var accounts = context.accounts(for: provider)
        if selectedFirst, let selected = meter.selected,
            let index = accounts.firstIndex(where: { $0.id == selected.id })
        {
            accounts.insert(accounts.remove(at: index), at: 0)
        }
        return accounts.map { card(for: $0, provider: provider) }
    }

    private func card(for account: AccountUsage, provider: ProviderID) -> CardModel {
        let id = CardID.account(provider, account.id)
        let isMain = provider == meter.provider && account.id == meter.selected?.id
        let summary: CardModel.Summary
        var details: [DetailSection] = []
        let disclosure: CardModel.Disclosure

        switch provider {
        case .claude, .codex:
            let resets = ResetsBuilder.model(account.resetAllowance, now: context.now)
            if context.settings.appearance.cardStyle == .rings {
                disclosure = .alwaysOpen
                summary = .rings(rings(account))
                if account.resetAllowance != nil { details.append(.resets(resets)) }
            } else {
                disclosure = disclosureState(id)
                summary = .bars(bars(account, provider: provider, resetSummary: resets.summary))
                let limits = gauges.scoped(account)
                if !limits.isEmpty { details.append(.limits(limits)) }
                details.append(.resets(resets))
            }
        case .cursor, .grok:
            disclosure = disclosureState(id)
            summary = .bars(simpleBars(account, provider: provider))
            let rows = account.windows.filter { $0.kind == .scoped && $0.usedPercent != nil }
            if provider == .cursor, !rows.isEmpty {
                details.append(.usageBars(rows.map(gauges.gauge)))
            }
        }
        if let tokens = TokenRowsBuilder(context: context).model(
            provider: provider, account: account.id)
        {
            details.append(.tokens(tokens))
        }
        return CardModel(
            id: id, provider: provider, title: account.name,
            plan: PlanBadge(plan: account.plan, verbatim: provider != .claude),
            sharesLogin: account.sharesLogin, isMain: isMain, disclosure: disclosure,
            summary: summary, details: details,
            status: status(for: account, provider: provider))
    }

    private func disclosureState(_ id: CardID) -> CardModel.Disclosure {
        context.settings.cards.expanded.contains(id) ? .expanded : .collapsed
    }

    private func rings(_ account: AccountUsage) -> RingsModel {
        let session = gauges.session(account)
        let weekly = gauges.weekly(account)
        return RingsModel(
            outer: weekly, inner: session, initial: Formatting.initial(account.name),
            rows: [session, weekly] + gauges.scoped(account))
    }

    /// Session and weekly bars for Claude and Codex. With neither value, one unknown session
    /// bar remains so the card never looks empty.
    private func bars(
        _ account: AccountUsage, provider: ProviderID, resetSummary: String?
    ) -> BarsModel {
        let session = account.bindingWindow(.session)
        let weekly = account.bindingWindow(.weekly)
        var bars: [GaugeModel] = []
        if session?.usedPercent != nil { bars.append(gauges.session(account)) }
        if weekly?.usedPercent != nil { bars.append(gauges.weekly(account)) }
        if bars.isEmpty { bars.append(gauges.session(account)) }

        var caption: [String] = []
        if let credits = account.balance(.credits) {
            if credits.isUnlimited {
                caption.append("Unlimited credits")
            } else if let amount = credits.amount, amount > 0 {
                caption.append(Formatting.credits(amount))
            }
        }
        if let resetSummary { caption.append(resetSummary) }
        return BarsModel(
            headline: bars[0], bars: bars,
            caption: caption.isEmpty ? nil : caption.joined(separator: " · "),
            showsBarLabels: true)
    }

    /// One bar for the provider's main window, with spend details in the caption.
    private func simpleBars(_ account: AccountUsage, provider: ProviderID) -> BarsModel {
        let main = account.windows.first { $0.kind != .scoped } ?? account.windows.first
        let gauge = main.map(gauges.gauge) ?? gauges.gauge(nil, title: "Usage", shortTitle: "usage")
        var caption: [String] = []
        if provider == .grok, let title = main?.title { caption.append(title) }
        if provider == .cursor, let spend = account.balance(.spend), let amount = spend.amount {
            caption.append("\(Formatting.money(amount, unit: spend.unit)) spent")
        }
        if provider == .grok, let onDemand = account.balance(.onDemand),
            let amount = onDemand.amount, amount > 0
        {
            let spent = Formatting.money(amount, unit: onDemand.unit)
            if let limit = onDemand.limit, limit > 0 {
                caption.append(
                    "On-demand \(spent) of \(Formatting.money(limit, unit: onDemand.unit))")
            } else {
                caption.append("On-demand \(spent)")
            }
        }
        if let reset = gauge.resetText { caption.append(reset) }
        return BarsModel(
            headline: gauge, bars: [gauge],
            caption: caption.isEmpty ? nil : caption.joined(separator: " · "),
            showsBarLabels: false)
    }

    /// Claude extra usage for the selected account, when Claude owns the menu bar.
    private func extraUsageCard() -> CardModel? {
        guard meter.provider == .claude, let account = meter.selected,
            let balance = account.balance(.extraUsage),
            balance.amount != nil || balance.limit != nil
        else { return nil }
        let spent = balance.amount.map { Formatting.money($0, unit: balance.unit) } ?? "—"
        let limit = balance.limit.flatMap {
            $0 > 0 ? Formatting.money($0, unit: balance.unit) : nil
        }
        let fraction = account.windows.first { $0.kind == .billing }?.usedPercent.map {
            min(1, $0 / 100)
        }
        return CardModel(
            id: .extraUsage, provider: .claude, title: "Extra usage", plan: nil, sharesLogin: false,
            isMain: false, disclosure: .alwaysOpen,
            summary: .extraUsage(
                ExtraUsageModel(
                    amountText: limit.map { "\(spent) / \($0)" } ?? spent,
                    isPaused: balance.isPaused, fraction: fraction)),
            details: [], status: nil)
    }

    /// The account's own issue first. Cards of providers that do not own the menu bar also
    /// state a failed refresh or old data; the main provider shows those above the hero.
    private func status(for account: AccountUsage, provider: ProviderID) -> StatusLine? {
        if let issue = account.issue {
            return StatusLine(text: NoticeText.text(for: issue, now: context.now), isFailure: true)
        }
        guard provider != meter.provider else { return nil }
        if context.readings[provider]?.isStale == true {
            return StatusLine(text: "Refresh failed · showing last known data", isFailure: true)
        }
        if account.isStale {
            return StatusLine(text: "Data may be stale", isFailure: false)
        }
        return nil
    }
}

/// Text for an issue, with a countdown when the provider allows a retry later.
enum NoticeText {
    static func text(for issue: UsageIssue, now: Date) -> String {
        guard let retryAt = issue.retryAt, let countdown = Countdown.text(until: retryAt, now: now)
        else { return issue.message }
        return "\(issue.message) Retrying in \(countdown)."
    }
}
