import Foundation
import MeterDomain

extension CardModel {
    /// The name that VoiceOver speaks: the provider and the account, or only the provider
    /// when the account is named after it, so it never says `Cursor Cursor`.
    public var spokenTitle: String {
        let provider = provider.displayName
        let title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty || title.caseInsensitiveCompare(provider) == .orderedSame {
            return provider
        }
        return "\(provider) \(title)"
    }

    /// The card can take over the menu bar: a Claude or Codex account that is not the main
    /// card. "Use in Menu Bar" moves it to the top, which pins it (`AppModel.moveCard`).
    public var canUseInMenuBar: Bool {
        !isMain && id.menuBarSelection != nil
    }
}

extension BarsModel {
    /// The spoken value of a bar card's header button: the headline, then whether the
    /// details show.
    public func headerAccessibilityValue(isExpanded: Bool) -> String {
        "\(headline.accessibilityValue). \(isExpanded ? "Expanded" : "Collapsed")"
    }
}

extension AccountsModel {
    /// Whether moving the card `offset` places works: the place is in the list, and the new
    /// first card can own the menu bar (``CardOrder/move(_:to:visible:saved:main:)``). The
    /// popover offers "Move up" and "Move down" only when this is true.
    public func canMove(_ id: CardID, by offset: Int) -> Bool {
        let ids = cards.map(\.id)
        guard let from = ids.firstIndex(of: id), offset != 0 else { return false }
        let main = cards.first(where: \.isMain)?.id
        let result = CardOrder.move(id, to: from + offset, visible: ids, saved: [], main: main)
        if case .moved = result { return true }
        return false
    }

    /// What VoiceOver announces after a card moves to `index`. A card that lands first owns
    /// the menu bar.
    public func moveAnnouncement(_ card: CardModel, to index: Int) -> String {
        if index == 0, card.id.menuBarSelection != nil {
            return "\(card.spokenTitle) is first and shows in the menu bar."
        }
        return "\(card.spokenTitle) moved to position \(index + 1) of \(cards.count)."
    }
}
