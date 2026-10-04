import MeterDomain

/// Identifies one card in the popover. Stored in ``CardSettings`` as text.
public enum CardID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// An account card. Cursor and Grok use ``AccountID/default``.
    case account(ProviderID, AccountID)
    /// Claude extra usage for the selected Claude account.
    case extraUsage

    /// `claude:claude-work`, `codex:/Users/me/.codex`, `cursor:default`, or `extra-usage`.
    public var rawValue: String {
        switch self {
        case .account(let provider, let account): "\(provider.rawValue):\(account.rawValue)"
        case .extraUsage: "extra-usage"
        }
    }

    public init?(rawValue: String) {
        if rawValue == "extra-usage" {
            self = .extraUsage
            return
        }
        guard let separator = rawValue.firstIndex(of: ":"),
            let provider = ProviderID(rawValue: String(rawValue[..<separator]))
        else { return nil }
        let account = rawValue[rawValue.index(after: separator)...]
        guard !account.isEmpty else { return nil }
        self = .account(provider, AccountID(String(account)))
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = CardID(rawValue: text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown card \(text)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The provider and account this card can make the main meter, if any.
    public var menuBarSelection: (provider: ProviderID, account: AccountID)? {
        guard case .account(let provider, let account) = self, provider.canOwnMenuBar else {
            return nil
        }
        return (provider, account)
    }
}
