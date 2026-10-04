/// A usage source. Raw values are stable storage keys.
public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case grok

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .grok: "Grok"
        }
    }

    /// Only Claude and Codex report rolling session and weekly limits, so only they can own
    /// the menu bar, the hero, and the first card.
    public var canOwnMenuBar: Bool {
        self == .claude || self == .codex
    }
}
