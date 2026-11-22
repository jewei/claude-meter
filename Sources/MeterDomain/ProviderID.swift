/// A usage source. Raw values are stable storage keys.
public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case grok
    case antigravity

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .grok: "Grok"
        case .antigravity: "Antigravity"
        }
    }

    /// Only Claude and Codex report rolling session and weekly limits, so only they can own
    /// the menu bar, the hero, and the first card.
    public var canOwnMenuBar: Bool {
        self == .claude || self == .codex
    }

    /// Whether the provider reports a token history for the card's "Tokens used" section.
    public var reportsTokenHistory: Bool {
        switch self {
        case .claude, .codex, .cursor, .grok: true
        case .antigravity: false
        }
    }
}

// Lets `[ProviderID: Value]` encode as a JSON object rather than a flat array.
extension ProviderID: CodingKeyRepresentable {}
