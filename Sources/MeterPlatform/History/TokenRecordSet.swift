import Foundation

/// Records that count once per key, such as one record per response ID.
///
/// A record without a key cannot have copies that are known, so it always counts. Use it for
/// a line that lacks an ID, and mark the history partial.
public struct TokenRecordSet: Hashable, Sendable {
    public private(set) var keyed: [String: TokenRecord] = [:]
    public private(set) var unkeyed: [TokenRecord] = []

    public init() {}

    public var count: Int { keyed.count + unkeyed.count }

    /// Adds `record`. A record with the key of an earlier record replaces it only by
    /// ``TokenRecord/replaces(_:)``.
    public mutating func insert(_ record: TokenRecord, key: String?) {
        guard let key else {
            unkeyed.append(record)
            return
        }
        if let existing = keyed[key], !record.replaces(existing) { return }
        keyed[key] = record
    }

    /// Adds every record of `other`, with the same rule as ``insert(_:key:)``.
    public mutating func formUnion(_ other: TokenRecordSet) {
        for (key, record) in other.keyed { insert(record, key: key) }
        unkeyed += other.unkeyed
    }

    /// Every record, once.
    public var records: [TokenRecord] { Array(keyed.values) + unkeyed }
}
