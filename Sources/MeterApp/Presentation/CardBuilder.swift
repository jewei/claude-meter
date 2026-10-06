import Foundation
import MeterDomain

/// Builds the card for every account, in automatic order.
struct CardBuilder {
    let context: PresentationContext
    let meter: MainMeter

    private var gauges: GaugeBuilder { GaugeBuilder(context: context) }

    /// Automatic order: the main provider's accounts with the selected one first, then Claude
    /// extra usage, then the other providers that can own the menu bar, then the rest, each in
    /// `ProviderID` order. Every provider gets cards without a change here.
    func cards() -> [CardModel] {
        var cards = accountCards(meter.provider, selectedFirst: true)
        if let extra = extraUsageCard() { cards.append(extra) }
        let others = ProviderID.allCases.filter { $0 != meter.provider }
        for provider in others.filter(\.canOwnMenuBar) + others.filter({ !$0.canOwnMenuBar }) {
            cards += accountCards(provider, selectedFirst: false)
        }
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
            let resets = ResetsBuilder.model(
                account.resetAllowance, now: context.now, calendar: context.calendar)
            disclosure = disclosureState(id)
            if context.settings.appearance.cardStyle == .rings {
                summary = .rings(rings(account))
                if account.resetAllowance != nil { details.append(.resets(resets)) }
            } else {
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
        // The extra-usage window: the share of the monthly limit spent.
        let window = account.windows.first { $0.kind == .billing && $0.usedPercent != nil }
        let gauge = gauges.gauge(window, title: "Extra usage", shortTitle: "extra")
        let shareText = gauge.caption.map { "\(gauge.valueText) \($0)" }
        let amount = limit.map { "\(spent) spent of \($0)" } ?? "\(spent) spent"
        var spoken = [amount]
        if window != nil { spoken.append(gauge.accessibilityValue) }
        if balance.isPaused { spoken.append("paused") }
        return CardModel(
            id: .extraUsage, provider: .claude, title: "Extra usage", plan: nil, sharesLogin: false,
            isMain: false, disclosure: .alwaysOpen,
            summary: .extraUsage(
                ExtraUsageModel(
                    amountText: limit.map { "\(spent) / \($0)" } ?? spent,
                    isPaused: balance.isPaused, fraction: window.map { _ in gauge.fraction },
                    severity: gauge.severity, shareText: shareText,
                    accessibilityValue: spoken.joined(separator: ", "))),
            details: [], status: nil)
    }

    /// The account's own issue first. Cards of providers that do not own the menu bar also
    /// state old data; the main provider shows it above the hero. A failed refresh of any
    /// provider is a notice (``Notice``), so the card never repeats it.
    private func status(for account: AccountUsage, provider: ProviderID) -> StatusLine? {
        if let issue = account.issue {
            return StatusLine(text: NoticeText.text(for: issue, now: context.now), isFailure: true)
        }
        guard provider != meter.provider else { return nil }
        if account.isStale {
            return StatusLine(text: "Data may be stale", isFailure: false)
        }
        return nil
    }
}
