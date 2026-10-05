import Foundation

/// Resets of a usage limit that the provider grants, such as Claude usage-limit resets and
/// Codex reset credits. The app only displays them and never uses one.
public struct ResetAllowance: Codable, Hashable, Sendable {
    public struct Reset: Codable, Hashable, Sendable {
        public let title: String
        /// When the reset expires. This is not a quota window reset time.
        public let expiresAt: Date?

        public init(title: String, expiresAt: Date?) {
            self.title = title
            self.expiresAt = DateBounds.validated(expiresAt)
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                title: try container.decode(String.self, forKey: .title),
                expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt))
        }
    }

    /// The authoritative number of resets available.
    public let available: Int
    /// Details for some or all available resets, sorted by expiry with unknown expiry last.
    /// Fewer details than `available` means the provider omitted some.
    public let resets: [Reset]

    public init(available: Int, resets: [Reset] = []) {
        self.available = max(0, available)
        self.resets = Array(
            resets.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
                .prefix(self.available))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            available: try container.decode(Int.self, forKey: .available),
            resets: try container.decode([Reset].self, forKey: .resets))
    }
}
