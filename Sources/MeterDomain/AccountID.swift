/// Identifies one account within one provider.
///
/// Claude uses the config-dir key (`claude`, `claude-work`), Codex the canonical home path,
/// and single-account providers use ``AccountID/default``. An ID selects a card; it never
/// proves who is signed in. ``AccountOwner`` does that.
public struct AccountID: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CodingKeyRepresentable, ExpressibleByStringLiteral, CustomStringConvertible
{
    /// The only account of a provider that has one login, such as Cursor or Grok.
    public static let `default`: AccountID = "default"

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var codingKey: any CodingKey {
        AnyCodingKey(rawValue)
    }

    public init?<T: CodingKey>(codingKey: T) {
        self.rawValue = codingKey.stringValue
    }

    public var description: String { rawValue }

    public static func < (lhs: AccountID, rhs: AccountID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
