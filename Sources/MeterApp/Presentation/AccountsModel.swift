import Foundation
import MeterDomain

/// The hero, notices, and cards.
public struct AccountsModel: Equatable, Sendable {
    public let notices: [Notice]
    public let hero: HeroModel
    public let cards: [CardModel]
    /// The ring legend, when any card is drawn as rings.
    public let ringLegend: RingLegendModel?
    /// Shown when more than one card can own the menu bar.
    public let dragHint: String?

    init(_ context: PresentationContext, meter: MainMeter, automatic: [CardModel]) {
        let ids = CardOrder.ordered(
            automatic: automatic.map(\.id), saved: context.settings.cards.order, main: meter.cardID)
        let byID = Dictionary(
            automatic.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cards = ids.compactMap { byID[$0] }
        hero = HeroModel(meter, context: context)
        notices = Notice.notices(context, meter: meter, cards: cards)
        let hasRings = cards.contains { if case .rings = $0.summary { true } else { false } }
        ringLegend = hasRings ? .standard : nil
        let eligible = cards.filter { $0.id.menuBarSelection != nil }.count
        dragHint = eligible > 1 ? "Drag a Claude or Codex card to the top for the menu bar." : nil
    }
}
